#!/bin/bash

# 该脚本用于快速创建本地 MySQL 测试库、测试表，并批量灌入 100 万条压测数据。
# 先生成 1000 行种子表，再按批次集合插入，兼容性比递归 CTE 更稳。

set -euo pipefail

# 允许调用方通过环境变量覆盖连接参数，避免把账号密码写死在命令行外部流程中。
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-root}"
MYSQL_CHARSET="${MYSQL_CHARSET:-utf8mb4}"
TARGET_DATABASE="${TARGET_DATABASE:-test}"
TARGET_TABLE="${TARGET_TABLE:-test_numbers_100w}"
TOTAL_ROWS="${TOTAL_ROWS:-1000000}"
BATCH_ROWS="${BATCH_ROWS:-1000}"

if (( TOTAL_ROWS <= 0 )); then
  echo "TOTAL_ROWS must be greater than 0" >&2
  exit 1
fi

if (( BATCH_ROWS <= 0 )); then
  echo "BATCH_ROWS must be greater than 0" >&2
  exit 1
fi

if (( TOTAL_ROWS % BATCH_ROWS != 0 )); then
  echo "TOTAL_ROWS must be divisible by BATCH_ROWS" >&2
  exit 1
fi

# 记录脚本总耗时，方便区分数据库执行慢还是结果统计慢。
SCRIPT_START_AT="$(date +%s)"

mysql \
  -h"${MYSQL_HOST}" \
  -P"${MYSQL_PORT}" \
  -u"${MYSQL_USER}" \
  -p"${MYSQL_PASSWORD}" \
  --default-character-set="${MYSQL_CHARSET}" <<SQL
SET @total_rows = ${TOTAL_ROWS};
SET @batch_rows = ${BATCH_ROWS};
SET @loop_count = @total_rows / @batch_rows;

-- 记录删库阶段耗时，便于区分初始化慢在清理还是建库。
SET @phase_start_at = NOW(6);

-- 清理旧测试库，保证每次执行的库内状态完全一致。
DROP DATABASE IF EXISTS \`${TARGET_DATABASE}\`;

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS drop_database_seconds;

SET @phase_start_at = NOW(6);

-- 创建测试库，统一字符集以避免后续导入时出现字符集不一致问题。
CREATE DATABASE IF NOT EXISTS \`${TARGET_DATABASE}\`
DEFAULT CHARACTER SET utf8mb4
DEFAULT COLLATE utf8mb4_general_ci;

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS create_database_seconds;

USE \`${TARGET_DATABASE}\`;

-- 记录各阶段耗时，便于定位慢点到底在 DDL、插入还是统计查询。
SET @phase_start_at = NOW(6);

-- 每次执行前先清理旧表，保证脚本可重复运行且结果稳定。
DROP TABLE IF EXISTS \`seed_0_999\`;
DROP TABLE IF EXISTS \`${TARGET_TABLE}\`;

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS drop_table_seconds;

SET @phase_start_at = NOW(6);

-- 测试表仅保留 id 和 num 两个非空字段，id 使用主键自增方便验证插入数量。
CREATE TABLE \`${TARGET_TABLE}\` (
    \`id\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键ID',
    \`num\` INT NOT NULL COMMENT '测试数值',
    \`name\` VARCHAR(64) NOT NULL COMMENT '测试字符串',
    PRIMARY KEY (\`id\`),
    KEY \`idx_num\` (\`num\`),
    KEY \`idx_name\` (\`name\`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='100万测试数据表';

CREATE TABLE \`seed_0_999\` (
    \`n\` INT NOT NULL,
    PRIMARY KEY (\`n\`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='0到999种子表';

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS create_table_seconds;

SET @phase_start_at = NOW(6);

INSERT INTO \`seed_0_999\` (\`n\`)
SELECT ones.n + tens.n * 10 + hundreds.n * 100
FROM (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) ones
CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) tens
CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) hundreds;

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS seed_table_seconds;

SET @phase_start_at = NOW(6);

-- 重建过程前先删除旧过程，避免重复执行时报对象已存在。
DROP PROCEDURE IF EXISTS \`seed_test_numbers\`;

DELIMITER $$

-- 按批次插入测试数据。
-- 这里默认选用 1000 行为一个批次，兼顾执行速度和单条 SQL 长度控制。
CREATE PROCEDURE \`seed_test_numbers\`()
BEGIN
    DECLARE v_batch_index INT DEFAULT 0;

    WHILE v_batch_index < @loop_count DO
        SET @offset = v_batch_index * @batch_rows;
        SET @insert_sql = CONCAT(
          'INSERT INTO \`${TARGET_TABLE}\` (\`num\`, \`name\`) ',
          'SELECT ',
          @offset, ' + \`n\` + 1, ',
          'CONCAT(''name_'', ', @offset, ' + \`n\` + 1) ',
          'FROM \`seed_0_999\` ORDER BY \`n\`'
        );

        PREPARE insert_stmt FROM @insert_sql;
        EXECUTE insert_stmt;
        DEALLOCATE PREPARE insert_stmt;

        SET v_batch_index = v_batch_index + 1;
    END WHILE;
END$$

DELIMITER ;

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS create_procedure_seconds;

SET @phase_start_at = NOW(6);

CALL \`seed_test_numbers\`();

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS insert_million_rows_seconds;

SET @phase_start_at = NOW(6);

-- 数据灌入完成后删除过程，避免测试库长期残留一次性对象。
DROP PROCEDURE IF EXISTS \`seed_test_numbers\`;
DROP TABLE IF EXISTS \`seed_0_999\`;

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS drop_procedure_seconds;

-- 单独记录统计查询起始时间，避免与前面的灌数耗时混在一起。
SET @stats_start_at = NOW(6);

-- 返回结果用于快速确认数据量是否符合预期。
SELECT COUNT(*) AS total_rows, MIN(\`num\`) AS min_num, MAX(\`num\`) AS max_num,
       MIN(\`name\`) AS min_name, MAX(\`name\`) AS max_name
FROM \`${TARGET_TABLE}\`;

-- 输出统计查询自身耗时，便于判断 COUNT 聚合扫描成本。
SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @stats_start_at, NOW(6)) / 1000000, 6) AS stats_seconds;
SQL

# 输出脚本端整体耗时，便于和数据库内部耗时做对比。
SCRIPT_END_AT="$(date +%s)"
echo "script_total_seconds=$((SCRIPT_END_AT - SCRIPT_START_AT))"

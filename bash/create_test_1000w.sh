#!/bin/bash

# 该脚本用于快速创建本地 MySQL 测试库、测试表，并批量灌入 1000 万条压测数据。
# 做法是先生成 1 万行种子序列表，再按批次通过集合插入扩展到 1000 万，避免逐条循环插入。

set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-root}"
MYSQL_CHARSET="${MYSQL_CHARSET:-utf8mb4}"

TARGET_DATABASE="${TARGET_DATABASE:-test}"
TARGET_TABLE="${TARGET_TABLE:-test_numbers_1000w}"
TOTAL_ROWS="${TOTAL_ROWS:-10000000}"
BATCH_ROWS="${BATCH_ROWS:-10000}"

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

SET @phase_start_at = NOW(6);

CREATE DATABASE IF NOT EXISTS \`${TARGET_DATABASE}\`
DEFAULT CHARACTER SET utf8mb4
DEFAULT COLLATE utf8mb4_general_ci;

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS create_database_seconds;

USE \`${TARGET_DATABASE}\`;

SET @phase_start_at = NOW(6);

DROP TABLE IF EXISTS \`seed_0_9999\`;
DROP TABLE IF EXISTS \`${TARGET_TABLE}\`;

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS drop_table_seconds;

SET @phase_start_at = NOW(6);

CREATE TABLE \`${TARGET_TABLE}\` (
  \`id\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键ID',
  \`num\` INT NOT NULL COMMENT '测试数值',
  \`name\` VARCHAR(64) NOT NULL COMMENT '测试字符串',
  PRIMARY KEY (\`id\`),
  KEY \`idx_num\` (\`num\`),
  KEY \`idx_name\` (\`name\`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='1000万测试数据表';

CREATE TABLE \`seed_0_9999\` (
  \`n\` INT NOT NULL,
  PRIMARY KEY (\`n\`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='0到9999种子表';

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS create_table_seconds;

SET @phase_start_at = NOW(6);

INSERT INTO \`seed_0_9999\` (\`n\`)
SELECT ones.n + tens.n * 10 + hundreds.n * 100 + thousands.n * 1000
FROM (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) ones
CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) tens
CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) hundreds
CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) thousands;

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS seed_table_seconds;

SET @phase_start_at = NOW(6);

DROP PROCEDURE IF EXISTS \`seed_large_test_numbers\`;

DELIMITER $$

CREATE PROCEDURE \`seed_large_test_numbers\`()
BEGIN
    DECLARE v_batch_index INT DEFAULT 0;

    WHILE v_batch_index < @loop_count DO
        SET @offset = v_batch_index * @batch_rows;
        SET @insert_sql = CONCAT(
          'INSERT INTO \`${TARGET_TABLE}\` (\`num\`, \`name\`) ',
          'SELECT ',
          @offset, ' + \`n\` + 1, ',
          'CONCAT(''name_'', ', @offset, ' + \`n\` + 1) ',
          'FROM \`seed_0_9999\` ORDER BY \`n\`'
        );

        PREPARE insert_stmt FROM @insert_sql;
        EXECUTE insert_stmt;
        DEALLOCATE PREPARE insert_stmt;

        SET v_batch_index = v_batch_index + 1;
    END WHILE;
END$$

DELIMITER ;

CALL \`seed_large_test_numbers\`();

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS insert_rows_seconds;

SET @phase_start_at = NOW(6);

DROP PROCEDURE IF EXISTS \`seed_large_test_numbers\`;
DROP TABLE IF EXISTS \`seed_0_9999\`;

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @phase_start_at, NOW(6)) / 1000000, 6) AS cleanup_seconds;

SET @stats_start_at = NOW(6);

SELECT COUNT(*) AS total_rows, MIN(\`num\`) AS min_num, MAX(\`num\`) AS max_num,
       MIN(\`name\`) AS min_name, MAX(\`name\`) AS max_name
FROM \`${TARGET_TABLE}\`;

SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, @stats_start_at, NOW(6)) / 1000000, 6) AS stats_seconds;
SQL

SCRIPT_END_AT="$(date +%s)"
echo "script_total_seconds=$((SCRIPT_END_AT - SCRIPT_START_AT))"

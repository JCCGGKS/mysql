# 1000 万数据插入优化方案

## 当前脚本的主要瓶颈

当前 [create_test_1000w.sh](/home/fanqicheng/project/jx/fincore/mysql/bash/create_test_1000w.sh) 的插数逻辑可以工作，但在 1000 万数据量下会明显偏慢，主要原因有以下几点：

1. 循环次数多  
   当前默认 `BATCH_ROWS=10000`，插入 1000 万行时需要循环 1000 次。每次循环都会执行一次 `PREPARE + EXECUTE + DEALLOCATE`，额外开销较大。

2. 插入时同步维护二级索引  
   当前表结构除了主键外，还有：
   - `idx_num (num)`
   - `idx_name (name)`
   
   在 1000 万行插入过程中，这两个索引会持续维护，写放大会比较明显。

3. 单批事务偏小  
   每批 1 万行，意味着事务提交次数较多。对于大批量灌数，这种分批粒度通常偏保守。

4. 动态 SQL 频繁拼接  
   当前每次循环都在存储过程中拼接一条新的 `INSERT INTO ... SELECT ...`，会增加 SQL 解析和执行器负担。

5. `VARCHAR` 字段增加了写入成本  
   当前插入不仅写 `num`，还写 `name VARCHAR(64)`，并且通过 `CONCAT('name_', num)` 动态构造字符串。与纯整数列相比，会增加 CPU 和页写入成本。


## 优化优先级

如果目标是尽快把 1000 万数据灌进去，建议按下面顺序优化。

### 1. 先插数据，再创建二级索引

这是最优先的优化项，通常收益最大。

建议建表时只保留主键：

```sql
CREATE TABLE test_numbers_1000w (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  num INT NOT NULL,
  name VARCHAR(64) NOT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

数据插入完成后，再补索引：

```sql
ALTER TABLE test_numbers_1000w ADD INDEX idx_num (num);
ALTER TABLE test_numbers_1000w ADD INDEX idx_name (name);
```

原因：

- 插入阶段只维护聚簇主键，写入压力更小
- 批量建索引通常比逐行维护索引更快


### 2. 放大批次

当前默认：

```bash
BATCH_ROWS=10000
```

建议优先尝试：

```bash
BATCH_ROWS=100000
```

这样 1000 万行只需要循环 100 次，而不是 1000 次。

收益：

- 减少存储过程循环次数
- 减少 `PREPARE/EXECUTE` 次数
- 减少事务提交次数

注意：

- 批次过大时，单次事务时间会增长
- 如果容器内存较小，可以从 `50000` 开始试


### 3. 减少动态 SQL 的执行次数

当前脚本在每个循环内都要拼接一次 SQL：

```sql
INSERT INTO target_table (num, name)
SELECT ...
FROM seed_0_9999
```

更好的思路是尽量用更少的 SQL 完成更多数据生成，例如：

1. 扩大种子表规模
2. 使用偏移表做笛卡尔积
3. 用更少的批次完成插入

例如：

- 种子表 `seed_0_9999` 负责 1 万行
- 偏移表负责 1000 个批次偏移
- 再通过一条或少量几条 `INSERT INTO ... SELECT ...` 写入目标表

这种思路的核心是减少循环，不是减少总行数。


### 4. 压测场景下临时降低刷盘强度

如果这是本地压测库、Docker 测试环境，且不要求强一致性，可以临时调整：

```sql
SET GLOBAL innodb_flush_log_at_trx_commit = 2;
SET GLOBAL sync_binlog = 0;
```

收益：

- 降低每次事务提交的刷盘成本
- 对大批量插入通常有明显帮助

限制：

- 只适合测试环境
- 不适合生产环境
- 需要有足够权限执行 `SET GLOBAL`


### 5. 如果只做压测，尽量简化字段和索引

如果你的目的只是做数量级压测，而不是验证复杂查询，可以进一步简化：

1. 去掉 `name` 字段  
   如果业务不依赖字符串列，纯整数表通常插入更快。

2. 去掉 `idx_name`  
   字符串索引比整数索引更重。

3. 如果 `num` 也不是查询条件，连 `idx_num` 也可以最后再补，或者完全不建。


## 推荐的落地方案

对于当前脚本，推荐先做下面这组最小改动。

### 方案 A：低风险、改动最小

1. 建表时只保留主键
2. `BATCH_ROWS` 从 `10000` 提升到 `100000`
3. 数据插入完成后再创建 `idx_num` 和 `idx_name`

这个方案改动最小，但通常就能带来明显收益。


### 方案 B：进一步减少循环

在方案 A 基础上继续优化：

1. 保留 `seed_0_9999`
2. 再构造一个批次偏移表，例如 `seed_batch`
3. 使用更少次数的 `INSERT INTO ... SELECT ...` 完成灌数

适合继续压榨性能，但脚本复杂度会提高。


### 方案 C：使用文件导入

如果目标是“尽可能快地生成 1000 万数据”，`LOAD DATA INFILE` 或 `LOAD DATA LOCAL INFILE` 通常会更快。

典型流程：

1. 先生成 CSV 文件
2. 再导入 MySQL

例如：

```sql
LOAD DATA LOCAL INFILE '/path/test_numbers_1000w.csv'
INTO TABLE test_numbers_1000w
FIELDS TERMINATED BY ','
LINES TERMINATED BY '\n'
(num, name);
```

优点：

- 往往比循环 `INSERT` 更快
- 更接近数据库原生批量导入路径

缺点：

- 需要额外生成文件
- 容器和客户端要支持 `LOCAL INFILE`


## 推荐执行顺序

如果希望快速验证收益，建议按下面顺序推进：

1. 去掉建表时的二级索引
2. 把 `BATCH_ROWS` 调到 `100000`
3. 插入完成后再加索引
4. 如果仍然慢，再考虑调低刷盘参数
5. 如果还不够，再改为 `LOAD DATA INFILE`


## 建议的验证方式

每次只改一个变量，避免多个改动叠加后无法判断收益来源。

建议记录以下指标：

1. 建表耗时
2. 插数耗时
3. 建索引耗时
4. 总耗时
5. 容器 CPU、内存、磁盘 IO 使用情况

这样能快速判断瓶颈到底在：

- SQL 执行次数
- 索引维护
- 磁盘刷盘
- 字符串字段写入


## 结论

对于当前 1000 万脚本，最值得先做的不是继续微调 SQL 语法，而是：

1. 插入阶段不维护二级索引
2. 放大批次，减少循环次数
3. 在测试环境中按需降低刷盘强度

如果目标只是尽快造数，最终速度通常取决于：

- 是否带二级索引插入
- 事务批次大小
- 容器磁盘性能
- 是否改用文件导入

在大多数本地或 Docker 压测环境里，“先插入，再建索引” 是收益最高、风险最低的一步。

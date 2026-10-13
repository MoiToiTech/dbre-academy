# Module 4 — Query execution plans and indexing

`time: ~80 min` · `lab: ./lab scenario setup 04-missing-index` · `level: fundamentals`

Most slow queries are not slow because the server is too small. They are slow
because they read a hundred thousand rows to return twenty, and the reason is
visible in one `EXPLAIN`. Indexes are also the cheapest performance fix a DBA
has, and the easiest to overdo: every index makes writes more expensive and
the buffer pool more crowded. This module teaches you to read execution
plans, design composite indexes that match the query, and remove the ones
that do not earn their keep.

## Learning objectives

By the end of this module you can:

- describe how InnoDB stores a table as a clustered index, and what a
  secondary index lookup costs;
- read `EXPLAIN` in traditional, `TREE` and `JSON` format, and compare
  estimates with reality using `EXPLAIN ANALYZE`;
- interpret access types, `key_len`, `rows`, `filtered` and the common
  `Extra` notes (`Using index`, `Using filesort`, `Using temporary`,
  `Using index condition`);
- design a composite index from a query: equality columns first, then one
  range or sort column, then columns to cover the select list;
- explain cardinality, selectivity, persistent statistics and histograms;
- test an index removal safely with an invisible index, and find redundant
  and unused indexes with the `sys` schema.

## Prerequisites

- Modules 1 to 3. The lab is running (`./lab up`) on the baseline dataset.
- Run commands from the `labs/` directory; SQL blocks go into `./lab sql`.
- The dataset is deterministic, so plans and row counts match what you see
  here. Row *estimates* come from sampled statistics and can differ slightly
  on your lab; timings always differ.

## 1. How InnoDB stores a table

Every InnoDB table **is** an index: a B+tree ordered by the primary key, the
**clustered index**, whose leaf pages hold the complete rows. Every other
index is a **secondary index**: a separate B+tree ordered by its own columns,
whose leaf entries hold those columns plus the primary key value
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-index-types.html)).

So a lookup through a secondary index is two tree searches: one in the
secondary index to find the primary key, then one in the clustered index to
fetch the row. Read 7 000 rows that way and you do 7 000 clustered index
lookups, in primary key order that has nothing to do with your query. Two
consequences shape everything in this module:

- If the secondary index already contains every column the query needs, the
  second search is skipped. That is a **covering index**.
- The primary key is copied into every secondary index entry. A wide primary
  key makes every index wider.

InnoDB's persistent statistics record each index's size in pages
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-persistent-stats.html)):

```sql test
SELECT index_name, stat_name, stat_value, stat_description
  FROM mysql.innodb_index_stats
 WHERE database_name = 'shop' AND table_name = 'orders'
 ORDER BY index_name, stat_name;
```

```text
+---------------------+--------------+------------+-----------------------------------+
| index_name          | stat_name    | stat_value | stat_description                  |
+---------------------+--------------+------------+-----------------------------------+
| PRIMARY             | n_diff_pfx01 |     199800 | id                                |
| PRIMARY             | n_leaf_pages |        600 | Number of leaf pages in the index |
| PRIMARY             | size         |        609 | Number of pages in the index      |
| idx_orders_customer | n_diff_pfx01 |      19635 | customer_id                       |
| idx_orders_customer | n_diff_pfx02 |     200232 | customer_id,id                    |
| idx_orders_customer | n_leaf_pages |        216 | Number of leaf pages in the index |
| idx_orders_customer | size         |        289 | Number of pages in the index      |
+---------------------+--------------+------------+-----------------------------------+
```

`orders` has 200 000 rows in 600 leaf pages of 16 KiB: about 330 rows per
page. `idx_orders_customer` holds only `(customer_id, id)` and fits in 216
leaf pages. `n_diff_pfx01` is the estimated number of distinct values in the
first column of the index; the true number of customers with orders is 19 732. The figures
are estimates from a sample of pages; yours may differ slightly.

## 2. Reading EXPLAIN

`EXPLAIN` shows the plan the optimizer chose without running the query
([manual](https://dev.mysql.com/doc/refman/8.4/en/explain.html)). A typical
API query, "the 20 latest orders of a customer":

```sql test
EXPLAIN
SELECT id, status, total_cents, created_at
  FROM shop.orders
 WHERE customer_id = 1
 ORDER BY created_at DESC
 LIMIT 20;
```

```text
+----+-------------+--------+------------+------+---------------------+---------------------+---------+-------+------+----------+----------------+
| id | select_type | table  | partitions | type | possible_keys       | key                 | key_len | ref   | rows | filtered | Extra          |
+----+-------------+--------+------------+------+---------------------+---------------------+---------+-------+------+----------+----------------+
|  1 | SIMPLE      | orders | NULL       | ref  | idx_orders_customer | idx_orders_customer | 4       | const | 7255 |   100.00 | Using filesort |
+----+-------------+--------+------------+------+---------------------+---------------------+---------+-------+------+----------+----------------+
```

The columns that matter most
([manual: EXPLAIN output format](https://dev.mysql.com/doc/refman/8.4/en/explain-output.html)):

| Column | Meaning |
|---|---|
| `type` | Access type: how rows are found (table below) |
| `key`, `key_len` | Index used, and how many bytes of it |
| `rows` | Estimated rows examined per lookup |
| `filtered` | Estimated % of those left after the `WHERE` |
| `Extra` | How the rest is done: sort, temp table, covering |

Read it as: InnoDB looks up customer 1 in `idx_orders_customer` (`ref`,
`const`), expects to examine 7 255 rows, and sorts them all
(`Using filesort`) to return 20.

### Access types, best to worst

| `type` | What happens |
|---|---|
| `const`, `eq_ref` | At most one row, via a primary key or unique index |
| `ref` | All rows matching one value of a non-unique index |
| `range` | Index rows between bounds (`<`, `BETWEEN`, `IN`) |
| `index` | The **whole** index is read, in index order |
| `ALL` | The whole table is read: a full table scan |

`index` is easy to misread as good: it means a full scan of an index instead
of the table. It is cheaper than `ALL` only because the index is smaller.

```sql test
EXPLAIN SELECT * FROM shop.orders WHERE id = 1000;
EXPLAIN SELECT o.id, i.line_no
          FROM shop.order_items i JOIN shop.orders o ON o.id = i.order_id
         WHERE i.product_id = 42;
EXPLAIN SELECT id FROM shop.orders WHERE id BETWEEN 1000 AND 1100;
EXPLAIN SELECT COUNT(*) FROM shop.orders;
EXPLAIN SELECT * FROM shop.orders WHERE total_cents > 1000000;
```

```text
+----+-------------+--------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
| id | select_type | table  | partitions | type  | possible_keys | key     | key_len | ref   | rows | filtered | Extra |
+----+-------------+--------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | orders | NULL       | const | PRIMARY       | PRIMARY | 8       | const |    1 |   100.00 | NULL  |
+----+-------------+--------+------------+-------+---------------+---------+---------+-------+------+----------+-------+
+----+-------------+-------+------------+--------+---------------------------------+-------------------------+---------+-----------------+------+----------+-------------+
| id | select_type | table | partitions | type   | possible_keys                   | key                     | key_len | ref             | rows | filtered | Extra       |
+----+-------------+-------+------------+--------+---------------------------------+-------------------------+---------+-----------------+------+----------+-------------+
|  1 | SIMPLE      | i     | NULL       | ref    | PRIMARY,idx_order_items_product | idx_order_items_product | 4       | const           |  521 |   100.00 | Using index |
|  1 | SIMPLE      | o     | NULL       | eq_ref | PRIMARY                         | PRIMARY                 | 8       | shop.i.order_id |    1 |   100.00 | Using index |
+----+-------------+-------+------------+--------+---------------------------------+-------------------------+---------+-----------------+------+----------+-------------+
+----+-------------+--------+------------+-------+-----------------------------+---------+---------+------+------+----------+--------------------------+
| id | select_type | table  | partitions | type  | possible_keys               | key     | key_len | ref  | rows | filtered | Extra                    |
+----+-------------+--------+------------+-------+-----------------------------+---------+---------+------+------+----------+--------------------------+
|  1 | SIMPLE      | orders | NULL       | range | PRIMARY,idx_orders_customer | PRIMARY | 8       | NULL |  101 |   100.00 | Using where; Using index |
+----+-------------+--------+------------+-------+-----------------------------+---------+---------+------+------+----------+--------------------------+
+----+-------------+--------+------------+-------+---------------+---------------------+---------+------+--------+----------+-------------+
| id | select_type | table  | partitions | type  | possible_keys | key                 | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+--------+------------+-------+---------------+---------------------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | orders | NULL       | index | NULL          | idx_orders_customer | 4       | NULL | 199800 |   100.00 | Using index |
+----+-------------+--------+------------+-------+---------------+---------------------+---------+------+--------+----------+-------------+
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
| id | select_type | table  | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | orders | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 199800 |    33.33 | Using where |
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
```

Notice the `COUNT(*)`: the optimizer reads the smallest index that has every
row, `idx_orders_customer`, rather than the much larger clustered index.

### rows × filtered

`rows` is how many rows the access method examines; `filtered` is the
estimated percentage that survive the remaining conditions. `rows ×
filtered / 100` is what the step passes on, and in a join that is how many
times the next table is probed. For the last query above the optimizer
guesses that a third of 199 800 rows have `total_cents > 1000000`, because it
has no statistics on an unindexed column. Section 6 shows how histograms fix
that guess.

### Extra: filesort and temporary tables

`Using filesort` means the rows are sorted after they are read, in memory if
they fit in `sort_buffer_size`, on disk if not. `Using temporary` means an
internal temporary table holds intermediate results, typically for
`GROUP BY` or `DISTINCT` on columns no index delivers in order
([manual](https://dev.mysql.com/doc/refman/8.4/en/internal-temporary-tables.html)):

```sql test
EXPLAIN SELECT status, COUNT(*) FROM shop.orders GROUP BY status;
```

```text
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-----------------+
| id | select_type | table  | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra           |
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-----------------+
|  1 | SIMPLE      | orders | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 199800 |   100.00 | Using temporary |
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-----------------+
```

Neither is a problem in itself on a few thousand rows. Both are worth a look
when they sit on top of a step that reads hundreds of thousands.

### EXPLAIN FORMAT=TREE and EXPLAIN ANALYZE

`FORMAT=TREE` prints the plan as the executor runs it: innermost operation
first, one line per step. `EXPLAIN ANALYZE` **runs the query** and adds what
actually happened: time to first and last row in milliseconds, rows
returned, and loops
([manual](https://dev.mysql.com/doc/refman/8.4/en/explain.html#explain-analyze)):

```sql test
EXPLAIN ANALYZE
SELECT id, status, total_cents, created_at
  FROM shop.orders
 WHERE customer_id = 1
 ORDER BY created_at DESC
 LIMIT 20\G
```

```text
*************************** 1. row ***************************
EXPLAIN: -> Limit: 20 row(s)  (cost=1182 rows=20) (actual time=4.97..4.97 rows=20 loops=1)
    -> Sort: shop.orders.created_at DESC, limit input to 20 row(s) per chunk  (cost=1182 rows=7255) (actual time=4.92..4.92 rows=20 loops=1)
        -> Index lookup on orders using idx_orders_customer (customer_id=1)  (cost=1182 rows=7255) (actual time=0.574..4.63 rows=7255 loops=1)
```

Read it from the inside out. The index lookup returned all 7 255 orders of
customer 1, the sort kept 20, the limit passed 20 on. Estimate and reality
agree here; when they do not (`rows=10` estimated, `rows=40000` actual), the
optimizer is working from bad statistics, and that is your lead. Because it
executes the query, do not run `EXPLAIN ANALYZE` on a statement you could not
afford to run; it can be stopped with `KILL QUERY` or Ctrl-C. It accepts
`SELECT`, `TABLE`, and multi-table `UPDATE` and `DELETE` statements.

### EXPLAIN FORMAT=JSON

The JSON format carries the optimizer's cost estimates and, most usefully,
`used_key_parts`: exactly which columns of the index were used. The
`04-missing-index` check reads it:

```sql test
EXPLAIN FORMAT=JSON
SELECT id, status, total_cents, created_at
  FROM shop.orders WHERE customer_id = 1 ORDER BY created_at DESC LIMIT 20\G
```

```text
*************************** 1. row ***************************
EXPLAIN: {
  "query_block": {
    "select_id": 1,
    "cost_info": {
      "query_cost": "1182.25"
    },
    "ordering_operation": {
      "using_filesort": true,
      "table": {
        "table_name": "orders",
        "access_type": "ref",
        "possible_keys": [
          "idx_orders_customer"
        ],
        "key": "idx_orders_customer",
        "used_key_parts": [
          "customer_id"
        ],
        "key_length": "4",
        "ref": [
          "const"
        ],
        "rows_examined_per_scan": 7255,
        "rows_produced_per_join": 7255,
        "filtered": "100.00",
        "cost_info": {
          "read_cost": "456.75",
          "eval_cost": "725.50",
          "prefix_cost": "1182.25",
          "data_read_per_join": "226K"
        },
        "used_columns": [
          "id",
          "customer_id",
          "status",
          "total_cents",
          "created_at"
        ]
      }
    }
  }
}
```

## 3. key_len: how much of the index is used

`key_len` is the number of bytes of the index key the access uses. Add up the
columns' storage sizes in index order
([manual: data type storage requirements](https://dev.mysql.com/doc/refman/8.4/en/storage-requirements.html)):

| Column type | Bytes in key_len |
|---|---|
| `INT`, `INT UNSIGNED` | 4 |
| `BIGINT` | 8 |
| `ENUM` (up to 255 values) | 1 |
| `DATETIME` | 5 |
| `VARCHAR(n)`, utf8mb4 | 4 × n + 2 |
| nullable column | + 1 |

In the plans above, `key_len 4` on `idx_orders_customer` is `customer_id`
(`INT UNSIGNED NOT NULL`), and `key_len 8` on `PRIMARY` is the `BIGINT` id.
When a composite index is used only partially, `key_len` is shorter than the
index: that is how you spot a query that uses the first column and not the
second. For `range` access it can be misleading; `used_key_parts` in
`FORMAT=JSON` is the definitive answer.

## 4. Composite indexes

A composite index sorts by its first column, then by the second within equal
first values, and so on, like a phone book sorted by surname then first name.
The optimizer can use it for any **leftmost prefix** of its columns
([manual](https://dev.mysql.com/doc/refman/8.4/en/multiple-column-indexes.html)).

For "latest 20 orders of a customer", the index should find the customer and
then deliver orders already sorted by date: `(customer_id, created_at)`.

```sql test
ALTER TABLE shop.orders
  ADD INDEX idx_orders_customer_created (customer_id, created_at);

EXPLAIN ANALYZE
SELECT id, status, total_cents, created_at
  FROM shop.orders
 WHERE customer_id = 1
 ORDER BY created_at DESC
 LIMIT 20\G
```

```text
*************************** 1. row ***************************
EXPLAIN: -> Limit: 20 row(s)  (cost=1182 rows=20) (actual time=0.414..0.422 rows=20 loops=1)
    -> Index lookup on orders using idx_orders_customer_created (customer_id=1) (reverse)  (cost=1182 rows=7255) (actual time=0.404..0.411 rows=20 loops=1)
```

The sort is gone. InnoDB walks customer 1's entries backwards (`reverse`, or
`Backward index scan` in traditional `EXPLAIN`) and stops after 20 rows: 20
rows read instead of 7 255. The `rows=7255` estimate is unchanged because it
describes the full index lookup; the `LIMIT` stops it early. This is why
`EXPLAIN ANALYZE` matters.

### Leftmost prefix

The same index cannot help a query that does not constrain `customer_id`:

```sql test
EXPLAIN SELECT id FROM shop.orders WHERE created_at >= '2025-12-01';
```

```text
+----+-------------+--------+------------+-------+-----------------------------+-----------------------------+---------+------+--------+----------+--------------------------+
| id | select_type | table  | partitions | type  | possible_keys               | key                         | key_len | ref  | rows   | filtered | Extra                    |
+----+-------------+--------+------------+-------+-----------------------------+-----------------------------+---------+------+--------+----------+--------------------------+
|  1 | SIMPLE      | orders | NULL       | index | idx_orders_customer_created | idx_orders_customer_created | 9       | NULL | 199800 |    33.33 | Using where; Using index |
+----+-------------+--------+------------+-------+-----------------------------+-----------------------------+---------+------+--------+----------+--------------------------+
```

`type: index` with 199 800 rows: the optimizer reads the entire index,
because orders from December are scattered under every customer. It picked
the index over the table only because the index is smaller and contains
everything this query needs (`Using index`).

### Range, then stop

Once the optimizer uses a range condition on a column, it does not use the
following index columns to narrow the search
([manual: range optimization](https://dev.mysql.com/doc/refman/8.4/en/range-optimization.html)).
Compare `BETWEEN` with an equivalent `IN` list:

```sql test
EXPLAIN ANALYZE SELECT id, total_cents FROM shop.orders
 WHERE customer_id BETWEEN 1 AND 3 AND created_at >= '2025-12-01'\G
EXPLAIN ANALYZE SELECT id, total_cents FROM shop.orders
 WHERE customer_id IN (1, 2, 3) AND created_at >= '2025-12-01'\G
```

```text
*************************** 1. row ***************************
EXPLAIN: -> Index range scan on orders using idx_orders_customer_created over (1 <= customer_id <= 3 AND '2025-12-01 00:00:00' <= created_at), with index condition: ((shop.orders.customer_id between 1 and 3) and (shop.orders.created_at >= TIMESTAMP'2025-12-01 00:00:00'))  (cost=1582 rows=3515) (actual time=0.334..0.435 rows=408 loops=1)

*************************** 1. row ***************************
EXPLAIN: -> Index range scan on orders using idx_orders_customer_created over (customer_id = 1 AND '2025-12-01 00:00:00' <= created_at) OR (customer_id = 2 AND '2025-12-01 00:00:00' <= created_at) OR (customer_id = 3 AND '2025-12-01 00:00:00' <= created_at), with index condition: ((shop.orders.customer_id in (1,2,3)) and (shop.orders.created_at >= TIMESTAMP'2025-12-01 00:00:00'))  (cost=184 rows=408) (actual time=0.0711..0.162 rows=408 loops=1)
```

Both return 408 rows. With `BETWEEN`, the index range covers every entry of
customers 1 to 3 (10 474 of them); `created_at` is checked on each entry by
**index condition pushdown**, InnoDB filtering inside the index before it
fetches rows
([manual](https://dev.mysql.com/doc/refman/8.4/en/index-condition-pushdown-optimization.html)).
With `IN`, each value is an equality, so the optimizer builds three ranges
that use both columns and reads only the 408 matching entries: the estimated
cost drops from 1 582 to 184. Index condition pushdown saved the `BETWEEN`
query from 10 000 row lookups, but it still walked 10 474 index entries.

The rule for designing a composite index from a query:

1. columns compared with `=` (or a short `IN` list) first;
2. then **one** column used for a range **or** for `ORDER BY`;
3. then, optionally, the remaining selected columns, to make it covering.

### Covering indexes

When every column the query reads is in the index, InnoDB never touches the
clustered index, and `Extra` shows `Using index`. Remember that the primary
key is part of every secondary index:

```sql test
EXPLAIN SELECT id, created_at FROM shop.orders
 WHERE customer_id = 1 ORDER BY created_at DESC LIMIT 20;
```

```text
+----+-------------+--------+------------+------+-------------------------------------------------+-----------------------------+---------+-------+------+----------+----------------------------------+
| id | select_type | table  | partitions | type | possible_keys                                   | key                         | key_len | ref   | rows | filtered | Extra                            |
+----+-------------+--------+------------+------+-------------------------------------------------+-----------------------------+---------+-------+------+----------+----------------------------------+
|  1 | SIMPLE      | orders | NULL       | ref  | idx_orders_customer,idx_orders_customer_created | idx_orders_customer_created | 4       | const | 7255 |   100.00 | Backward index scan; Using index |
+----+-------------+--------+------------+------+-------------------------------------------------+-----------------------------+---------+-------+------+----------+----------------------------------+
```

`id` and `created_at` both come from `idx_orders_customer_created`. Adding
`status` and `total_cents` to the index would make the original API query
covering too; whether that is worth a wider index is a trade-off against
section 9.

Now the original index is a prefix of the new one. `sys.schema_redundant_indexes`
spots that
([manual](https://dev.mysql.com/doc/refman/8.4/en/sys-schema-redundant-indexes.html)):

```sql test
SELECT redundant_index_name, redundant_index_columns,
       dominant_index_name, dominant_index_columns
  FROM sys.schema_redundant_indexes
 WHERE table_schema = 'shop';
```

```text
+----------------------+-------------------------+-----------------------------+------------------------+
| redundant_index_name | redundant_index_columns | dominant_index_name         | dominant_index_columns |
+----------------------+-------------------------+-----------------------------+------------------------+
| idx_orders_customer  | customer_id             | idx_orders_customer_created | customer_id,created_at |
+----------------------+-------------------------+-----------------------------+------------------------+
```

Keep that in mind for section 8.

## 5. Selectivity, cardinality and statistics

**Selectivity** is the fraction of rows a condition keeps; **cardinality**
is the number of distinct values in an index, as `SHOW INDEX` reports it
([manual](https://dev.mysql.com/doc/refman/8.4/en/show-index.html)). The
optimizer compares the cost of plans using these estimates, so the plan is
only as good as the statistics.

Averages hide skew. `customer_id` has 19 732 distinct values, so on
average a customer has 10 orders. In this shop, as in real ones, a few
customers place most orders:

```sql test
EXPLAIN SELECT id FROM shop.orders WHERE customer_id = 1;
EXPLAIN SELECT id FROM shop.orders WHERE customer_id = 20000;
```

```text
+----+-------------+--------+------------+------+-------------------------------------------------+---------------------+---------+-------+------+----------+-------------+
| id | select_type | table  | partitions | type | possible_keys                                   | key                 | key_len | ref   | rows | filtered | Extra       |
+----+-------------+--------+------------+------+-------------------------------------------------+---------------------+---------+-------+------+----------+-------------+
|  1 | SIMPLE      | orders | NULL       | ref  | idx_orders_customer,idx_orders_customer_created | idx_orders_customer | 4       | const | 7255 |   100.00 | Using index |
+----+-------------+--------+------------+------+-------------------------------------------------+---------------------+---------+-------+------+----------+-------------+
+----+-------------+--------+------------+------+-------------------------------------------------+---------------------+---------+-------+------+----------+-------------+
| id | select_type | table  | partitions | type | possible_keys                                   | key                 | key_len | ref   | rows | filtered | Extra       |
+----+-------------+--------+------------+------+-------------------------------------------------+---------------------+---------+-------+------+----------+-------------+
|  1 | SIMPLE      | orders | NULL       | ref  | idx_orders_customer,idx_orders_customer_created | idx_orders_customer | 4       | const |    3 |   100.00 | Using index |
+----+-------------+--------+------------+------+-------------------------------------------------+---------------------+---------+-------+------+----------+-------------+
```

For a handful of equality values the optimizer does not use the average: it
performs **index dives**, reading the index to count the matching entries,
so it knows customer 1 has 7 255 orders and customer 20 000 has 3. Above
`eq_range_index_dive_limit` values (200 by default) in an `IN` list it falls
back to the cardinality average
([manual](https://dev.mysql.com/doc/refman/8.4/en/range-optimization.html#equality-range-optimization)).

### Persistent statistics and ANALYZE TABLE

InnoDB stores table and index statistics in `mysql.innodb_table_stats` and
`mysql.innodb_index_stats`. It recalculates them automatically after about
10 % of a table's rows have changed (`innodb_stats_auto_recalc`), from
`innodb_stats_persistent_sample_pages` sampled pages (20 by default)
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-persistent-stats.html)).
`ANALYZE TABLE` recalculates them now
([manual](https://dev.mysql.com/doc/refman/8.4/en/analyze-table.html)):

```sql test
ANALYZE TABLE shop.orders;
SELECT table_name, n_rows, clustered_index_size, sum_of_other_index_sizes
  FROM mysql.innodb_table_stats
 WHERE database_name = 'shop' AND table_name = 'orders';
```

```text
+-------------+---------+----------+----------+
| Table       | Op      | Msg_type | Msg_text |
+-------------+---------+----------+----------+
| shop.orders | analyze | status   | OK       |
+-------------+---------+----------+----------+
+------------+--------+----------------------+--------------------------+
| table_name | n_rows | clustered_index_size | sum_of_other_index_sizes |
+------------+--------+----------------------+--------------------------+
| orders     | 199800 |                  609 |                      642 |
+------------+--------+----------------------+--------------------------+
```

`n_rows` is an estimate (the table has exactly 200 000).
`sum_of_other_index_sizes` has grown from 289 to 642 pages: it now includes
`idx_orders_customer_created`. After a bulk load
or a large delete, run `ANALYZE TABLE` before trusting a plan. For InnoDB it
is cheap: it samples pages instead of reading the table, and only needs a
brief lock at the end.

## 6. Histograms

Index statistics cover indexed columns only. For a condition on an unindexed
column, the optimizer guesses. A **histogram** records the distribution of
values in one column, so the guess becomes an estimate
([manual](https://dev.mysql.com/doc/refman/8.4/en/optimizer-statistics.html)).
Order statuses are heavily skewed: 60 % delivered, 3 % pending.

```sql test
EXPLAIN SELECT id FROM shop.orders WHERE status = 'pending';
ANALYZE TABLE shop.orders UPDATE HISTOGRAM ON status WITH 16 BUCKETS;
EXPLAIN SELECT id FROM shop.orders WHERE status = 'pending';
EXPLAIN SELECT id FROM shop.orders WHERE status = 'delivered';
```

```text
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
| id | select_type | table  | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | orders | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 199800 |    16.67 | Using where |
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
+-------------+-----------+----------+---------------------------------------------------+
| Table       | Op        | Msg_type | Msg_text                                          |
+-------------+-----------+----------+---------------------------------------------------+
| shop.orders | histogram | status   | Histogram statistics created for column 'status'. |
+-------------+-----------+----------+---------------------------------------------------+
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
| id | select_type | table  | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | orders | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 199800 |     2.99 | Using where |
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
| id | select_type | table  | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra       |
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
|  1 | SIMPLE      | orders | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 199800 |    59.94 | Using where |
+----+-------------+--------+------------+------+---------------+------+---------+------+--------+----------+-------------+
```

`filtered` moves from a flat 16.67 % (one in six enum values) to 2.99 % for
`pending` and 59.94 % for `delivered`, the real proportions. The access
method is still a table scan: a histogram improves estimates, it does not
make anything faster by itself. It matters in joins, where `filtered`
decides which table to read first and how often the other one is probed.

Histograms are stored in the data dictionary and visible in
`information_schema.COLUMN_STATISTICS`. Unlike index statistics they are not
refreshed automatically unless created with `AUTO UPDATE`; drop them when
you are done:

```sql test
SELECT SCHEMA_NAME, TABLE_NAME, COLUMN_NAME,
       HISTOGRAM->>'$."histogram-type"' AS type,
       HISTOGRAM->>'$."last-updated"' AS last_updated
  FROM information_schema.COLUMN_STATISTICS;
ANALYZE TABLE shop.orders DROP HISTOGRAM ON status;
```

```text
+-------------+------------+-------------+-----------+----------------------------+
| SCHEMA_NAME | TABLE_NAME | COLUMN_NAME | type      | last_updated               |
+-------------+------------+-------------+-----------+----------------------------+
| shop        | orders     | status      | singleton | 2026-10-13 10:54:06.270231 |
+-------------+------------+-------------+-----------+----------------------------+
+-------------+-----------+----------+---------------------------------------------------+
| Table       | Op        | Msg_type | Msg_text                                          |
+-------------+-----------+----------+---------------------------------------------------+
| shop.orders | histogram | status   | Histogram statistics removed for column 'status'. |
+-------------+-----------+----------+---------------------------------------------------+
```

Prefer an index when the column is used to find rows; consider a histogram
when the column only filters, an index would be poorly selective, or the
write cost of another index is not worth it.

## 7. Descending and functional indexes

**Descending indexes** store a column in reverse order
([manual](https://dev.mysql.com/doc/refman/8.4/en/descending-indexes.html)).
An ascending index can be read backwards, as section 4 showed, so `DESC`
only matters when one `ORDER BY` mixes directions:

```sql test
ALTER TABLE shop.orders
  ADD INDEX idx_orders_customer_created_desc (customer_id, created_at DESC),
  ALTER INDEX idx_orders_customer_created INVISIBLE;
EXPLAIN FORMAT=TREE SELECT id, created_at FROM shop.orders
 WHERE customer_id IN (1, 2, 3)
 ORDER BY customer_id, created_at DESC LIMIT 10\G
ALTER TABLE shop.orders
  DROP INDEX idx_orders_customer_created_desc,
  ALTER INDEX idx_orders_customer_created VISIBLE;
EXPLAIN FORMAT=TREE SELECT id, created_at FROM shop.orders
 WHERE customer_id IN (1, 2, 3)
 ORDER BY customer_id, created_at DESC LIMIT 10\G
```

```text
*************************** 1. row ***************************
EXPLAIN: -> Limit: 10 row(s)  (cost=3290 rows=10)
    -> Filter: (shop.orders.customer_id in (1,2,3))  (cost=3290 rows=16275)
        -> Covering index range scan on orders using idx_orders_customer_created_desc over (customer_id = 1) OR (customer_id = 2) OR (customer_id = 3)  (cost=3290 rows=16275)

*************************** 1. row ***************************
EXPLAIN: -> Limit: 10 row(s)  (cost=3290 rows=10)
    -> Sort: shop.orders.customer_id, shop.orders.created_at DESC, limit input to 10 row(s) per chunk  (cost=3290 rows=16275)
        -> Filter: (shop.orders.customer_id in (1,2,3))  (cost=3290 rows=16275)
            -> Covering index range scan on orders using idx_orders_customer_created over (customer_id = 1) OR (customer_id = 2) OR (customer_id = 3)  (cost=3290 rows=16275)
```

With `(customer_id, created_at DESC)` the rows come out of the index in the
requested order; with the ascending index the optimizer adds a sort.

**Functional key parts** index an expression instead of a column
([manual](https://dev.mysql.com/doc/refman/8.4/en/create-index.html#create-index-functional-key-parts)).
A condition that wraps the column in a function cannot use a plain index on
it:

```sql test
EXPLAIN FORMAT=TREE
SELECT COUNT(*) FROM shop.orders WHERE DATE(created_at) = '2025-12-24'\G
ALTER TABLE shop.orders ADD INDEX idx_orders_created_date ((DATE(created_at)));
EXPLAIN FORMAT=TREE
SELECT COUNT(*) FROM shop.orders WHERE DATE(created_at) = '2025-12-24'\G
ALTER TABLE shop.orders DROP INDEX idx_orders_created_date;
```

```text
*************************** 1. row ***************************
EXPLAIN: -> Aggregate: count(0)  (cost=40112 rows=1)
    -> Filter: (cast(shop.orders.created_at as date) = '2025-12-24')  (cost=20132 rows=199800)
        -> Covering index scan on orders using idx_orders_customer_created  (cost=20132 rows=199800)

*************************** 1. row ***************************
EXPLAIN: -> Aggregate: count(0)  (cost=123 rows=1)
    -> Index lookup on orders using idx_orders_created_date (cast(created_at as date)='2025-12-24')  (cost=95.5 rows=273)
```

Without the functional index, every one of the 199 800 entries of an index
(or the table) is read and the expression evaluated on each. With it, the
lookup goes straight to the 273 orders of that day. The functional index is
used only when the query contains the same expression. Usually the better fix is to rewrite the condition as a range on
the bare column (`created_at >= '2025-12-24' AND created_at < '2025-12-25'`),
which a normal index on `created_at` serves. Module 5 covers such
non-sargable conditions in depth.

## 8. Invisible indexes: test before you drop

Dropping an index on a large table is quick; recreating it when a forgotten
monthly report needed it is not. An **invisible index** is maintained on
every write but ignored by the optimizer, so you can see what breaks before
you commit to the drop
([manual](https://dev.mysql.com/doc/refman/8.4/en/invisible-indexes.html)):

```sql test
ALTER TABLE shop.orders ALTER INDEX idx_orders_customer INVISIBLE;
EXPLAIN SELECT id, status FROM shop.orders WHERE customer_id = 20000;
SELECT INDEX_NAME, IS_VISIBLE FROM information_schema.STATISTICS
 WHERE TABLE_SCHEMA = 'shop' AND TABLE_NAME = 'orders' AND SEQ_IN_INDEX = 1;
ALTER TABLE shop.orders ALTER INDEX idx_orders_customer VISIBLE;
```

```text
+----+-------------+--------+------------+------+-----------------------------+-----------------------------+---------+-------+------+----------+-------+
| id | select_type | table  | partitions | type | possible_keys               | key                         | key_len | ref   | rows | filtered | Extra |
+----+-------------+--------+------------+------+-----------------------------+-----------------------------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | orders | NULL       | ref  | idx_orders_customer_created | idx_orders_customer_created | 4       | const |    3 |   100.00 | NULL  |
+----+-------------+--------+------------+------+-----------------------------+-----------------------------+---------+-------+------+----------+-------+
+-----------------------------+------------+
| INDEX_NAME                  | IS_VISIBLE |
+-----------------------------+------------+
| idx_orders_customer         | NO         |
| idx_orders_customer_created | YES        |
| PRIMARY                     | YES        |
+-----------------------------+------------+
```

The redundant `idx_orders_customer` is invisible and the query uses the
composite index instead; nothing got worse. Making an index visible again is
instant; recreating a dropped one rebuilds it from the table. A session can
test with invisible indexes switched on with
`SET optimizer_switch = 'use_invisible_indexes=on'`.

Two cautions:

- Some indexes cannot be dropped at all. An index that backs a foreign key
  is required while the constraint exists, unless another index can take
  over:

  ```sql test expect-error
  ALTER TABLE shop.order_items DROP INDEX idx_order_items_product;
  ```

  ```text
  ERROR 1553 (HY000) at line 1: Cannot drop index 'idx_order_items_product': needed in a foreign key constraint
  ```

  `idx_orders_customer` could be dropped now only because
  `idx_orders_customer_created` starts with `customer_id`.
- An invisible index still costs what a visible one costs on writes, and a
  unique index still enforces uniqueness. Invisibility is a test, not a
  saving.

## 9. What indexes cost

Every secondary index is another B+tree that `INSERT` and `DELETE` must
modify, and `UPDATE` too when it changes an indexed column. In MySQL 8.4
change buffering is off by default (`innodb_change_buffering = none`), so
each of those changes needs the index page in the buffer pool
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-change-buffer.html)).
Indexes also take disk space, buffer pool space and backup time. To see the
write cost, load the same 200 000 orders into two copies, one with four extra
secondary indexes:

```sql test
CREATE DATABASE lab;
CREATE TABLE lab.orders_lean LIKE shop.orders;
CREATE TABLE lab.orders_heavy LIKE shop.orders;
ALTER TABLE lab.orders_heavy
  ADD INDEX idx_status_created (status, created_at),
  ADD INDEX idx_created (created_at),
  ADD INDEX idx_customer_created (customer_id, created_at),
  ADD INDEX idx_total (total_cents);
SET @t = NOW(6);
INSERT INTO lab.orders_lean SELECT * FROM shop.orders;
SELECT 'lean: 1 secondary index' AS copy,
       ROUND(TIMESTAMPDIFF(MICROSECOND, @t, NOW(6)) / 1e6, 2) AS seconds;
SET @t = NOW(6);
INSERT INTO lab.orders_heavy SELECT * FROM shop.orders;
SELECT 'heavy: 5 secondary indexes' AS copy,
       ROUND(TIMESTAMPDIFF(MICROSECOND, @t, NOW(6)) / 1e6, 2) AS seconds;
ANALYZE TABLE lab.orders_lean, lab.orders_heavy;
SELECT table_name, SUM(stat_value) * @@innodb_page_size DIV 1048576 AS total_mib
  FROM mysql.innodb_index_stats
 WHERE database_name = 'lab' AND stat_name = 'size'
 GROUP BY table_name ORDER BY table_name;
DROP DATABASE lab;
```

```text
+-------------------------+---------+
| copy                    | seconds |
+-------------------------+---------+
| lean: 1 secondary index |    0.97 |
+-------------------------+---------+
+----------------------------+---------+
| copy                       | seconds |
+----------------------------+---------+
| heavy: 5 secondary indexes |    1.46 |
+----------------------------+---------+
+------------------+---------+----------+----------+
| Table            | Op      | Msg_type | Msg_text |
+------------------+---------+----------+----------+
| lab.orders_lean  | analyze | status   | OK       |
| lab.orders_heavy | analyze | status   | OK       |
+------------------+---------+----------+----------+
+--------------+-----------+
| table_name   | total_mib |
+--------------+-----------+
| orders_heavy |        46 |
| orders_lean  |        23 |
+--------------+-----------+
```

Your timings will differ. In our runs the copy with five secondary indexes
took 1.5 to 2 times as long to load, and it is twice the size for the same
rows. On a busy OLTP primary that cost is paid
on every write, and replicas pay it again when they apply the changes.

## 10. Finding redundant and unused indexes

Two `sys` views do the bookkeeping:

- `sys.schema_redundant_indexes` lists indexes that are a leftmost prefix of
  another index (section 4). Usually safe to drop, after checking foreign
  keys and making them invisible first.
- `sys.schema_unused_indexes` lists indexes with no reads recorded by the
  Performance Schema since the server started
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/sys-schema-unused-indexes.html)).

```sql test
SELECT * FROM sys.schema_unused_indexes WHERE object_schema = 'shop';
```

```text
+---------------+-------------+-----------------------------+
| object_schema | object_name | index_name                  |
+---------------+-------------+-----------------------------+
| shop          | orders      | idx_orders_customer         |
| shop          | orders      | idx_orders_customer_created |
| shop          | payments    | idx_payments_order          |
| shop          | products    | idx_products_category       |
+---------------+-------------+-----------------------------+
```

Your list depends on which queries have run since the lab started, which is
exactly the problem with this view. Even `idx_orders_customer_created`, which
the `EXPLAIN ANALYZE` examples read, is listed: adding or dropping an index
on a table restarts the Performance Schema counters for all of that table's
indexes, and section 7 did both. Treat the view as a list of suspects:

- "Since the server started" may be one quiet hour, or may not include the
  month-end report.
- It covers this server only. A replica serving reports uses different
  indexes from the primary.
- Foreign key checks do not show up as index reads. `idx_payments_order` may
  well be listed, and it backs `fk_payments_order`: it cannot be dropped.

Finish the lesson by removing the composite index, so the lab is back at its
baseline:

```sql test
ALTER TABLE shop.orders DROP INDEX idx_orders_customer_created;
ANALYZE TABLE shop.orders;
```

## Common mistakes and troubleshooting

| Symptom in EXPLAIN | Likely cause |
|---|---|
| `type: ALL` on a big table | No usable index, or a function on the column |
| Index used, `rows` far above result | Index serves only part of the `WHERE` |
| `Using filesort` with `LIMIT` | Index does not match the `ORDER BY` |
| `type: index` | Full index scan; leftmost prefix not used |

- **One index per column.** MySQL usually uses one index per table access.
  Three single-column indexes are not a composite index.
- **Range column first.** `(created_at, status)` for
  `status = ? AND created_at >= ?` scans every status in the date range.
  Equality first, range last.
- **Trusting `rows` for `LIMIT` queries.** The estimate ignores early
  termination; `EXPLAIN ANALYZE` shows what was read.
- **Indexing low-cardinality columns alone.** An index on `status` that
  matches 60 % of rows is slower than a table scan, and the optimizer knows
  it. Combine it with a selective column, or use a histogram.
- **Stale statistics after bulk changes.** Run `ANALYZE TABLE` and compare the
  plan again.
- **Dropping "unused" indexes from one view.** Check foreign keys, replicas
  and the reporting calendar, and go through `INVISIBLE` first.
- **`EXPLAIN ANALYZE` on a query that takes an hour.** It runs the query in
  full. Start with plain `EXPLAIN`.

## Further reading

- [Optimization and indexes](https://dev.mysql.com/doc/refman/8.4/en/optimization-indexes.html)
- [How MySQL uses indexes](https://dev.mysql.com/doc/refman/8.4/en/mysql-indexes.html)
- [Understanding the query execution plan](https://dev.mysql.com/doc/refman/8.4/en/execution-plan-information.html)
- [ORDER BY optimization](https://dev.mysql.com/doc/refman/8.4/en/order-by-optimization.html)
- [Configuring persistent optimizer statistics](https://dev.mysql.com/doc/refman/8.4/en/innodb-persistent-stats.html)
- [Optimizer statistics (histograms)](https://dev.mysql.com/doc/refman/8.4/en/optimizer-statistics.html)

## Next

Do the [exercise](exercise.md): a support dashboard that scans the whole
orders table. Then the [quiz](quiz.md). Module 5 moves from single queries
to the whole server: finding which queries hurt, with the slow log,
Performance Schema digests and `sys`.

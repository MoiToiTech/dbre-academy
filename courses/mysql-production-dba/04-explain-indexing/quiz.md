# Module 4 — Quiz

Answer from memory first, then open the answer.

**1. A query reads 5 000 rows through a secondary index and needs columns
that are not in the index. How many B+tree searches does InnoDB do, roughly?**

<details><summary>Answer</summary>

One range scan of the secondary index, plus one clustered index lookup per
row: about 5 000 primary key lookups. If the index contained every column
the query needs (a covering index), the clustered index lookups would
disappear.

</details>

**2. Why does `SELECT COUNT(*) FROM shop.orders` use `idx_orders_customer`
instead of the primary key?**

<details><summary>Answer</summary>

Every index has an entry for every row, and the secondary index is much
smaller than the clustered index, which holds the full rows. Reading the
smallest complete index is the cheapest way to count.

</details>

**3. `EXPLAIN` shows `type: index`, `rows: 199800`, `Extra: Using index`. Is
this a good plan?**

<details><summary>Answer</summary>

Usually not. `index` means a full scan of the index; `Using index` only
says the scan does not need the table rows. It is cheaper than `ALL` because
the index is smaller, but it still reads every entry. It typically means the
query does not constrain the index's leftmost column.

</details>

**4. An index `(customer_id, created_at)` exists. Which of these can use it
to narrow the search: (a) `WHERE customer_id = 7`, (b)
`WHERE created_at > '2025-12-01'`, (c)
`WHERE customer_id = 7 AND created_at > '2025-12-01'`,
(d) `WHERE customer_id = 7 ORDER BY created_at`?**

<details><summary>Answer</summary>

(a), (c) and (d). (b) does not constrain the leftmost column, so it can at
best scan the whole index. In (d) the index also delivers rows in
`created_at` order, so there is no sort.

</details>

**5. `WHERE customer_id BETWEEN 1 AND 3 AND created_at >= '2025-12-01'` and
`WHERE customer_id IN (1, 2, 3) AND created_at >= '2025-12-01'` return the
same rows. Why can the second be much cheaper with
`(customer_id, created_at)`?**

<details><summary>Answer</summary>

After a range condition on one column, the range optimizer uses no further
key parts to narrow the search, so `BETWEEN` reads every entry of customers
1 to 3. An `IN` list is a set of equalities, so the optimizer builds one
range per value that also uses `created_at`, and reads only the matching
entries.

</details>

**6. Plan A: `rows 7255, filtered 100.00`. EXPLAIN ANALYZE of the same query:
`actual rows=20`. Is the estimate wrong?**

<details><summary>Answer</summary>

Not necessarily. `rows` estimates what the access method would examine if
it ran to completion; a `LIMIT` that stops the index scan early is not
reflected in it. `EXPLAIN ANALYZE` shows what actually happened.

</details>

**7. What does `key_len: 4` tell you for a query using a
`(customer_id, created_at)` index with `customer_id INT UNSIGNED NOT NULL`?**

<details><summary>Answer</summary>

Only the first key part, `customer_id` (4 bytes), is used for the lookup.
If `created_at` (a 5-byte `DATETIME`) were used too, `key_len` would be 9.
For range access, confirm with `used_key_parts` in `EXPLAIN FORMAT=JSON`.

</details>

**8. The optimizer estimates `filtered: 16.67` for `status = 'pending'`,
but only 3 % of orders are pending. What explains the guess, and what fixes
it without adding an index?**

<details><summary>Answer</summary>

`status` is not indexed, so there are no statistics on its distribution;
the optimizer assumes an even spread over the six enum values. A histogram
(`ANALYZE TABLE shop.orders UPDATE HISTOGRAM ON status`) gives it the real
distribution. It improves estimates, not the access method.

</details>

**9. You want to drop an index that `sys.schema_unused_indexes` lists. Name
three reasons it may still be needed.**

<details><summary>Answer</summary>

Any three of: the counters only cover the time since the server started,
or since the table's indexes last changed, which may miss a monthly job; the
index may be used on replicas, which have their own counters; foreign key
checks do not count as index reads, and the index may back a foreign key; a
unique index enforces a constraint even if no query reads it. Make it
invisible first and watch before dropping.

</details>

**10. A colleague makes an index invisible "to speed up inserts". Does it?**

<details><summary>Answer</summary>

No. An invisible index is still maintained on every write; only the
optimizer ignores it. It is a way to test the effect of dropping an index,
and it can be made visible again instantly.

</details>

**11. A query filters on `WHERE DATE(created_at) = '2025-12-24'` and an index
on `created_at` exists, yet the plan scans. Give two fixes.**

<details><summary>Answer</summary>

Rewrite the condition as a range on the bare column
(`created_at >= '2025-12-24' AND created_at < '2025-12-25'`), which the
existing index can serve; or add a functional index on
`(DATE(created_at))`, which is used only by queries containing that exact
expression. The rewrite is usually better, since it needs no extra index.

</details>

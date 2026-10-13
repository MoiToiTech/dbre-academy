# Module 4 — Exercise

## The support dashboard scans every order (`04-missing-index`)

Allow about 20 minutes. The reference fix is in
`labs/scenarios/04-missing-index/solve.sh`; try first.

```bash test
./lab scenario setup 04-missing-index
```

```text
Scenario 04-missing-index is set up.

  The support dashboard lists orders still pending since 1 December. It is
  slow, and it gets slower as shop.orders grows. Its query:

    SELECT id, customer_id, total_cents, created_at
      FROM shop.orders
     WHERE status = 'pending'
       AND created_at >= '2025-12-01'
     ORDER BY created_at;

  Make it read only the rows it returns, without a sort. Change the schema,
  not the query. Then: ./lab check 04-missing-index
```

### Your tasks

1. Find the query the way you would in production, from the statement
   digests rather than from the ticket. `sys.statements_with_full_table_scans`
   lists normalised statements that read tables without an index:

   ```sql test
   SELECT query, exec_count, rows_examined_avg, rows_sent_avg
     FROM sys.statements_with_full_table_scans
    WHERE query LIKE 'SELECT `id` , `customer_id`%';
   ```

   ```text
   +-------------------------------------------------------------------+------------+-------------------+---------------+
   | query                                                             | exec_count | rows_examined_avg | rows_sent_avg |
   +-------------------------------------------------------------------+------------+-------------------+---------------+
   | SELECT `id` , `customer_id` ,  ... at` >= ? ORDER BY `created_at` |          5 |            200238 |           238 |
   +-------------------------------------------------------------------+------------+-------------------+---------------+
   ```

   About 200 000 rows examined for 238 sent, on every execution.

2. Read the plan with `EXPLAIN` and `EXPLAIN ANALYZE`. What is the access
   type, how many rows does it examine, and what is in `Extra`?

   ```sql test
   EXPLAIN SELECT id, customer_id, total_cents, created_at
     FROM shop.orders
    WHERE status = 'pending' AND created_at >= '2025-12-01'
    ORDER BY created_at;
   ```

3. Work out the selectivity of each condition on its own:
   how many orders are `pending`, and how many were created since
   1 December? Which single-column index would help more, and would either
   be enough?
4. Design and create the index. Check your plan with `EXPLAIN FORMAT=JSON`:
   look at `used_key_parts`, `rows_examined_per_scan` and `using_filesort`.
5. Run the check:

   ```bash
   ./lab check 04-missing-index
   ```

   ```text
   Checking 04-missing-index
     plan: access=range key=idx_orders_status_created rows=238 used_key_parts=["status", "created_at"] filesort=false
     PASS the query uses an index (idx_orders_status_created)
     PASS the plan examines 238 rows (limit 500)
     PASS the index serves both the status equality and the created_at range
     PASS no filesort: rows come out of the index in ORDER BY order
   All checks passed.
   ```

Before you add an index, the check fails on every point:

```bash test expect-error
./lab check 04-missing-index
```

<details>
<summary>Hint 1</summary>

5 979 orders are pending; 8 001 were created since 1 December. Either
single-column index narrows the scan to a few thousand rows that are then
mostly thrown away. An index on `status` still needs a sort; one on
`created_at` avoids the sort but reads all 8 001 December orders to find 238
pending ones. Try one and run the check: it tells you which part is missing.

</details>

<details>
<summary>Hint 2</summary>

Equality columns first, then the one range column. The range column is also
the `ORDER BY` column, which is what removes the sort.

</details>

<details>
<summary>Discussion</summary>

`(status, created_at)` puts all pending orders together, sorted by date.
InnoDB seeks to `('pending', '2025-12-01 00:00:00')` and reads forward until
the status changes: exactly the 238 entries it returns, already in
`ORDER BY` order. The plan is `range` on both key parts with
`rows_examined_per_scan: 238`.

The column order matters. `(created_at, status)` looks equivalent but is
not: its range on `created_at` comes first, so the optimizer estimates
14 400 entries to examine and checks `status` on each through index
condition pushdown. `EXPLAIN ANALYZE` reports only 238 rows for it, because
pushdown filters inside the index; that is why the check reads the
optimizer's `rows_examined_per_scan` and `used_key_parts` rather than the
actual row count.

`(status, created_at, customer_id, total_cents)` also passes and makes the
query covering (`Using index`). On a 200 000-row table the difference is
small; on a large one it saves 238 clustered index lookups per execution, at
the cost of a wider index to maintain on every write.

`status` alone is a poor index for most queries: six values, 60 % of rows in
one of them. It is useful here only as the first column of a composite index,
for a query that asks for a rare value.

</details>

Reset when you are done; it removes any index you added to `shop.orders`
and restores the baseline:

```bash test
./lab scenario reset 04-missing-index
```

## Stretch: retire a redundant index safely

Without a scenario, on the baseline lab:

1. Add `idx_orders_customer_created (customer_id, created_at)` and confirm
   that `sys.schema_redundant_indexes` now reports `idx_orders_customer`.
2. Make `idx_orders_customer` invisible. Which queries from the lesson change
   plan? Does `fk_orders_customer` still work (try inserting an order for a
   customer id that does not exist)?
3. Decide: would you drop it in production? What would you check first, and
   on which servers?
4. Put everything back: make the index visible again and drop
   `idx_orders_customer_created`, or run
   `./lab scenario reset 04-missing-index`, which restores the indexes on
   `shop.orders`.

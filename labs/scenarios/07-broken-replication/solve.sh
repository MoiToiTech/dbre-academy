#!/usr/bin/env bash
# Reference fix. The primary is the source of truth, so:
#   1062 on customers 20001: the replica's own row is in the way. Delete it
#        (without binary logging) and let the applier insert the real one.
#   1032 on inventory (7, RIX): the row the primary updates is missing on the
#        replica. Put back the before image from the failing event (without
#        binary logging) and let the applier update it.
#   The replica's two errant GTIDs: their data effect is now gone, so commit
#        empty transactions with those GTIDs on the primary.
. "$LAB_DIR/scripts/lib.sh"

pg="$(sqlv primary 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')"
before="$(dc exec -T primary cat /backups/07-broken-replication/.errant-before)"
errant="$(sqlv replica "SELECT GTID_SUBTRACT(GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$pg'), '$before')" | tr -d '\n')"
echo "errant on the replica: $errant"

# The inventory row as it was before this morning's update. Students read
# the before image from the failing Update_rows event (mysqlbinlog -v); here
# it is reconstructed from the primary's current row.
row="$(sqlv primary "SELECT CONCAT_WS(',', product_id, QUOTE(warehouse), on_hand + 2, reserved,
                                       QUOTE(updated_at))
                     FROM shop.inventory WHERE product_id = 7 AND warehouse = 'RIX'")"
# (updated_at differs from the before image. The applier finds the row by
#  its primary key and writes the full after image, so the result is the
#  primary's row either way.)

sql replica <<SQL
STOP REPLICA;
SET SESSION sql_log_bin = 0;
SET GLOBAL super_read_only = OFF;
DELETE FROM shop.customers WHERE id = 20001;
INSERT INTO shop.inventory (product_id, warehouse, on_hand, reserved, updated_at) VALUES ($row);
SET GLOBAL super_read_only = ON;
START REPLICA;
SQL

# Make the primary aware of the errant GTIDs, one empty transaction each.
# The set has the form uuid:a-b[:c-d...] (one server's UUID: the replica's).
uuid="${errant%%:*}"
for range in $(tr ':' ' ' <<<"${errant#*:}"); do
  for i in $(seq "${range%-*}" "${range#*-}"); do
    sql primary -e "SET GTID_NEXT = '$uuid:$i'; BEGIN; COMMIT; SET GTID_NEXT = 'AUTOMATIC';"
  done
done
wait_replica_caught_up 120 || die "replica did not catch up"

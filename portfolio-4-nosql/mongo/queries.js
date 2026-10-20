// =====================================================================
// AquaFlow - MongoDB Demonstration Queries
// MIT 8103 Advanced Database Systems - Portfolio 4
//
// Run with: mongosh aquaflow --quiet --file queries.js
// =====================================================================

function heading(title, note) {
  print("\n======================================================================");
  print(" " + title);
  print("======================================================================");
  if (note) print(note + "\n");
}

// Summarise an explain("executionStats") result: the plan's stages from
// top to bottom, and how much work the query actually did
function planSummary(explain) {
  const stages = [];
  let s = explain.queryPlanner.winningPlan;
  while (s) {
    stages.push(s.stage + (s.indexName ? " (" + s.indexName + ")" : ""));
    s = s.inputStage || (s.inputStages ? s.inputStages[0] : null);
  }
  const e = explain.executionStats;
  return {
    plan: stages.join(" <- "),
    documents_examined: e.totalDocsExamined,
    index_keys_examined: e.totalKeysExamined,
    returned: e.nReturned,
    time_ms: e.executionTimeMillis
  };
}

// ---------------------------------------------------------------------
heading("1. What was loaded");
const deliveryStats = db.deliveries.stats();
const positionStats = db.runCommand({ collStats: "tanker_positions" });
const points = db.tanker_positions.countDocuments();
printjson({
  deliveries: db.deliveries.countDocuments(),
  average_delivery_document_bytes: Math.round(deliveryStats.avgObjSize),
  deliveries_on_disk_mb: +(deliveryStats.storageSize / 1048576).toFixed(1),
  gps_points: points,
  gps_buckets: db.getCollection("system.buckets.tanker_positions").countDocuments(),
  gps_on_disk_mb: +(positionStats.storageSize / 1048576).toFixed(1),
  gps_bytes_per_point_on_disk: Math.round(positionStats.storageSize / points)
});
print("Each bucket holds the GPS points from one tanker over a time window,");
print("stored compressed. That is why there are far fewer buckets than points,");
print("and why each point costs only a few bytes on disk.");

// ---------------------------------------------------------------------
heading("2. Tracking screen: one read returns the whole delivery",
"In PostgreSQL this screen joins delivery_request, trip, trip_status_history,\n" +
"tanker, vendor and driver (Portfolio 2, Q2). Here every attempt and its\n" +
"timeline are embedded, so it is a single lookup by _id.");
const retried = db.deliveries.findOne(
  { status: "completed", "attempts.1": { $exists: true } }, { _id: 1 });
printjson(db.deliveries.findOne(
  { _id: retried._id },
  { status: 1, "address.area": 1, "attempts.tanker.plate": 1, "attempts.status": 1,
    "attempts.failure_reason": 1, "attempts.timeline": 1 }));
printjson(planSummary(db.deliveries.find({ _id: retried._id }).explain("executionStats")));

// ---------------------------------------------------------------------
heading("3. Customer history: before and after an index",
"A customer's 20 most recent deliveries, newest first.");
const busiest = db.deliveries.aggregate([
  { $group: { _id: "$customer.id", n: { $sum: 1 } } },
  { $sort: { n: -1 } }, { $limit: 1 }
]).next()._id;
const historyQuery = () =>
  db.deliveries.find({ "customer.id": busiest }, { created_at: 1, status: 1, volume_litres: 1 })
    .sort({ created_at: -1 }).limit(20);

// Remove the index if a previous run created it, so "before" is measured without it
try { db.deliveries.dropIndex("customer_history"); } catch (e) { /* not there yet */ }
print("Before (customer " + busiest + "):");
printjson(planSummary(historyQuery().explain("executionStats")));

db.deliveries.createIndex({ "customer.id": 1, created_at: -1 }, { name: "customer_history" });
print("After creating index { 'customer.id': 1, created_at: -1 }:");
printjson(planSummary(historyQuery().explain("executionStats")));

// ---------------------------------------------------------------------
heading("4. Driver reports arrival: an atomic update inside one document",
"The positional operator $ targets the attempt matching trip_id. The status\n" +
"change and the new timeline entry are applied together: MongoDB guarantees\n" +
"that all changes to a single document are atomic.");
const active = db.deliveries.findOne(
  { status: "assigned", "attempts.status": "en_route" }, { "attempts.trip_id": 1, "attempts.status": 1 });
const trip = active.attempts.find(a => a.status === "en_route").trip_id;
const arrival = db.deliveries.updateOne(
  { _id: active._id, "attempts.trip_id": trip },
  { $set:  { "attempts.$.status": "arrived" },
    $push: { "attempts.$.timeline": { status: "arrived", at: new Date() } } });
printjson({ delivery: active._id, trip: trip, matched: arrival.matchedCount, modified: arrival.modifiedCount });
printjson(db.deliveries.findOne({ _id: active._id }, { "attempts.status": 1, "attempts.timeline": 1 }).attempts);

// ---------------------------------------------------------------------
heading("5. Flexible schema: optional data only some deliveries have",
"Some vendors test water quality on delivery. In PostgreSQL this needs a new\n" +
"table or nullable columns and a migration. Here the reading is simply added\n" +
"to the deliveries that have one.");
const tested = db.deliveries.findOne({ status: "completed", "attempts.1": { $exists: false } }, { _id: 1, "attempts.trip_id": 1 });
db.deliveries.updateOne(
  { _id: tested._id },
  { $set: { "attempts.0.water_quality": { tds_ppm: 180, chloride_mg_per_l: 95, ph: 7.2, tested_at: new Date() } } });
printjson(db.deliveries.findOne({ _id: tested._id }, { "attempts.water_quality": 1 }).attempts[0]);
printjson({
  deliveries_with_water_test: db.deliveries.countDocuments({ "attempts.water_quality": { $exists: true } }),
  deliveries_with_access_notes: db.deliveries.countDocuments({ "address.access_notes": { $exists: true } }),
  deliveries_with_refunds: db.deliveries.countDocuments({ "payment.refunds": { $exists: true } })
});

// ---------------------------------------------------------------------
heading("6. Validation: the flexible schema still has rules",
"The $jsonSchema validator rejects a delivery with a negative volume and\n" +
"no location, even though MongoDB has no fixed table structure.");
try {
  db.deliveries.insertOne({
    _id: NumberLong("999999999"),
    customer: { id: 1, name: "Test", type: "household" },
    address: { street: "1 Test Street", area: "Ikoyi" },
    volume_litres: -500,
    quoted_price: NumberDecimal("1000.00"),
    status: "pending",
    created_at: new Date(),
    attempts: []
  });
  print("Inserted (unexpected)");
} catch (e) {
  print("Rejected: " + e.message);
  const rules = e.errInfo.details.schemaRulesNotSatisfied[0].propertiesNotSatisfied;
  rules.forEach(r => print("  - " + r.propertyName + ": " + JSON.stringify(r.details[0].reason || r.details[0].operatorName)));
}

// ---------------------------------------------------------------------
heading("7. Aggregation: why trips fail",
"$unwind turns each attempt into its own record, then failed ones are grouped by reason.");
db.deliveries.aggregate([
  { $unwind: "$attempts" },
  { $match: { "attempts.status": "failed" } },
  { $group: { _id: "$attempts.failure_reason", trips: { $sum: 1 } } },
  { $sort: { trips: -1 } }
]).forEach(r => print(String(r.trips).padStart(6) + "  " + r._id));

heading("8. Aggregation: delivery performance by area",
"Average minutes from assignment to completion, and average rating.");
db.deliveries.aggregate([
  { $unwind: "$attempts" },
  { $match: { "attempts.status": "completed" } },
  { $group: {
      _id: "$address.area",
      deliveries: { $sum: 1 },
      avg_minutes: { $avg: { $dateDiff: { startDate: "$attempts.assigned_at",
                                          endDate: "$attempts.completed_at", unit: "minute" } } },
      avg_rating: { $avg: "$rating.score" } } },
  { $project: { deliveries: 1, avg_minutes: { $round: ["$avg_minutes", 0] }, avg_rating: { $round: ["$avg_rating", 2] } } },
  { $sort: { deliveries: -1 } }
]).forEach(r => printjson(r));

// ---------------------------------------------------------------------
heading("9. Geospatial: demand hotspots",
"Deliveries within 500 metres of the Adeola Odeku / Ahmadu Bello junction,\n" +
"Victoria Island, grouped by street. Uses the 2dsphere index.");
const junction = { type: "Point", coordinates: [3.4195, 6.4315] };
db.deliveries.aggregate([
  { $geoNear: { near: junction, distanceField: "metres", maxDistance: 500, spherical: true } },
  // Strip the house number ("12 Ahmadu Bello Way" -> "Ahmadu Bello Way") and group by street
  { $group: { _id: { $getField: { field: "match", input: { $regexFind: { input: "$address.street", regex: /[A-Za-z].*/ } } } },
              deliveries: { $sum: 1 }, nearest_m: { $min: "$metres" } } },
  { $project: { street: "$_id", deliveries: 1, nearest_m: { $round: ["$nearest_m", 0] }, _id: 0 } },
  { $sort: { deliveries: -1 } }
]).forEach(r => printjson(r));

// ---------------------------------------------------------------------
heading("10. Time series: a tanker's route for one trip",
"GPS breadcrumbs from assignment to arrival, read in time order.");
const routeTrip = db.tanker_positions.findOne({}, { "meta.trip_id": 1 }).meta.trip_id;
db.tanker_positions.find({ "meta.trip_id": routeTrip }, { _id: 0, ts: 1, location: 1, speed_kmh: 1 })
  .sort({ ts: 1 })
  .forEach(p => print(p.ts.toISOString().substring(11, 19) + "  " +
                      p.location.coordinates[1].toFixed(5) + ", " + p.location.coordinates[0].toFixed(5) +
                      "  " + String(p.speed_kmh).padStart(3) + " km/h"));

// ---------------------------------------------------------------------
heading("11. The cost of embedding",
"Vendor names are copied into every delivery they served. Renaming a vendor\n" +
"is one row in PostgreSQL but many documents here. (For history this copy\n" +
"is arguably correct: it records who the vendor was at the time.)");
const sampleVendor = db.deliveries.findOne({}, { "attempts.tanker.vendor_id": 1 }).attempts[0].tanker.vendor_id;
const rename = db.deliveries.updateMany(
  { "attempts.tanker.vendor_id": sampleVendor },
  { $set: { "attempts.$[a].tanker.vendor_name": "Renamed Water Ltd" } },
  { arrayFilters: [{ "a.tanker.vendor_id": sampleVendor }] });
printjson({ vendor: sampleVendor, documents_updated: rename.modifiedCount });

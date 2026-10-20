// =====================================================================
// AquaFlow - MongoDB collections
// MIT 8103 Advanced Database Systems - Portfolio 4
//
// Creates the two collections, with validation and indexes.
// Run with: mongosh aquaflow --quiet --file setup.js
// =====================================================================

db.deliveries.drop();
db.tanker_positions.drop();

// ---------------------------------------------------------------------
// deliveries: one document per delivery request.
//
// Schemaless does not have to mean unvalidated. $jsonSchema enforces
// the fields every delivery must have and their types, while optional
// details (access notes, refunds, ratings, extra vendor data) can still
// vary from document to document.
// ---------------------------------------------------------------------
db.createCollection("deliveries", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "customer", "address", "volume_litres", "quoted_price", "status", "created_at", "attempts"],
      properties: {
        _id:           { bsonType: ["int", "long"], description: "PostgreSQL delivery_request.id" },
        customer: {
          bsonType: "object",
          required: ["id", "name", "type"],
          properties: {
            id:   { bsonType: ["int", "long"] },
            name: { bsonType: "string" },
            type: { enum: ["household", "business"] }
          }
        },
        address: {
          bsonType: "object",
          required: ["street", "area", "location"],
          properties: {
            location: {
              bsonType: "object",
              required: ["type", "coordinates"],
              properties: {
                type:        { enum: ["Point"] },
                coordinates: { bsonType: "array", minItems: 2, maxItems: 2 }
              }
            }
          }
        },
        volume_litres: { bsonType: ["int", "long"], minimum: 1 },
        quoted_price:  { bsonType: "decimal" },
        status:        { enum: ["pending", "assigned", "completed", "cancelled"] },
        created_at:    { bsonType: "date" },
        attempts: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["trip_id", "tanker", "driver", "status", "assigned_at", "timeline"],
            properties: {
              status:   { enum: ["assigned", "en_route", "arrived", "completed", "failed", "cancelled"] },
              timeline: { bsonType: "array" }
            }
          }
        }
      }
    }
  },
  validationLevel: "strict",
  validationAction: "error"
});

// Geospatial index on delivery locations (used for demand hotspots)
db.deliveries.createIndex({ "address.location": "2dsphere" }, { name: "address_location_2dsphere" });

// Multikey index: one entry per attempt, so "every delivery a tanker made" is indexed
db.deliveries.createIndex({ "attempts.tanker.id": 1 }, { name: "attempts_tanker" });

// Partial index: only deliveries still in progress (a small fraction)
db.deliveries.createIndex(
  { status: 1, created_at: -1 },
  { name: "active_deliveries", partialFilterExpression: { status: { $in: ["pending", "assigned"] } } }
);

// ---------------------------------------------------------------------
// tanker_positions: GPS breadcrumbs as a time-series collection.
// MongoDB groups points from the same tanker and time window into
// compressed buckets, and deletes points older than 30 days itself.
// Granularity should match how often points arrive: the generated
// routes have a point about every 10 minutes, so "minutes" lets each
// bucket cover a longer window and hold more points.
// ---------------------------------------------------------------------
db.createCollection("tanker_positions", {
  timeseries: { timeField: "ts", metaField: "meta", granularity: "minutes" },
  expireAfterSeconds: 60 * 60 * 24 * 30
});
db.tanker_positions.createIndex({ "meta.trip_id": 1, ts: 1 }, { name: "trip_route" });

print("Collections created: " + db.getCollectionNames().sort().join(", "));

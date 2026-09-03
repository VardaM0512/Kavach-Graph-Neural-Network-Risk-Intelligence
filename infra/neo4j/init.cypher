// Kavach Neo4j schema (the relationship store).
// Run once against a fresh database:
//   cat infra/neo4j/init.cypher | cypher-shell -u neo4j -p kavachpass

// --- constraints / indexes ---
CREATE CONSTRAINT company_id IF NOT EXISTS
  FOR (c:Company) REQUIRE c.id IS UNIQUE;

CREATE INDEX company_industry IF NOT EXISTS
  FOR (c:Company) ON (c.industry);

// --- relationship types used by the graph model ---
//   (:Company)-[:SUPPLIES     {weight}]->(:Company)
//   (:Company)-[:CUSTOMER_OF  {weight}]->(:Company)
//   (:Company)-[:OWNS         {stake}]->(:Company)
//   (:Company)-[:BORROWS_FROM {weight}]->(:Bank)
//   (:Company)-[:SAME_INDUSTRY]->(:Company)

// --- tiny seed example (replace with your ETL) ---
MERGE (a:Company {id:'C0001', name:'Alpha Corp', industry:'Manufacturing'})
MERGE (b:Company {id:'C0002', name:'Beta Ltd',   industry:'Materials'})
MERGE (c:Company {id:'C0003', name:'Gamma Inc',  industry:'Retail'})
MERGE (b)-[:SUPPLIES {weight:0.48}]->(a)
MERGE (a)-[:CUSTOMER_OF {weight:0.30}]->(c)
MERGE (a)-[:SAME_INDUSTRY]->(b);

// --- example: 1-hop neighbourhood used by the graph screen ---
// MATCH (c:Company {id:$id})-[r]-(n:Company)
// RETURN n.id AS id, type(r) AS rel, coalesce(r.weight,1.0) AS weight;

"""Optional Neo4j layer (the relationship store).

Neo4j holds the company graph: SUPPLIES / CUSTOMER_OF / OWNS / BORROWS_FROM /
SAME_INDUSTRY edges. The ML graph builder can read from here instead of the
synthetic generator. Unset `KAVACH_NEO4J_URI` to run on synthetic data.

Example query used by the graph screen:

    MATCH (c:Company {id:$id})-[r]-(n:Company)
    RETURN n.id AS id, type(r) AS rel, r.weight AS weight
"""
from __future__ import annotations

from ..core.config import get_settings

_driver = None


def is_configured() -> bool:
    return bool(get_settings().neo4j_uri)


def get_driver():  # pragma: no cover - requires a live DB
    global _driver
    if not is_configured():
        return None
    if _driver is None:
        from neo4j import GraphDatabase
        s = get_settings()
        _driver = GraphDatabase.driver(s.neo4j_uri, auth=(s.neo4j_user, s.neo4j_password))
    return _driver


def neighbours(company_id: str) -> list[dict]:  # pragma: no cover
    driver = get_driver()
    if not driver:
        return []
    q = ("MATCH (c:Company {id:$id})-[r]-(n:Company) "
         "RETURN n.id AS id, type(r) AS rel, coalesce(r.weight,1.0) AS weight")
    with driver.session() as session:
        return [dict(rec) for rec in session.run(q, id=company_id)]


def healthcheck() -> bool:  # pragma: no cover
    driver = get_driver()
    if not driver:
        return False
    with driver.session() as session:
        session.run("RETURN 1")
    return True

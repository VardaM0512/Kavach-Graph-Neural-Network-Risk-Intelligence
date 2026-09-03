#!/usr/bin/env python3
"""Build docs/Kavach_Architecture_Guide.pdf.

Renders the Mermaid diagrams with mermaid-cli (mmdc) and assembles a styled,
study-guide-format PDF with ReportLab. Run:

    python docs/build_pdf.py

Requirements: reportlab, and mmdc on PATH (npm i -g @mermaid-js/mermaid-cli).
Set PUPPETEER_EXECUTABLE_PATH if Chromium isn't auto-detected.
"""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm, mm
from reportlab.platypus import (
    BaseDocTemplate, Frame, Image, PageBreak, PageTemplate, Paragraph,
    Spacer, Table, TableStyle, KeepTogether,
)

HERE = Path(__file__).resolve().parent
DIAG = HERE / "_diagrams"
DIAG.mkdir(exist_ok=True)
OUT = HERE / "Kavach_Architecture_Guide.pdf"

NAVY = colors.HexColor("#1F2A44")
BLUE = colors.HexColor("#2563EB")
ORANGE = colors.HexColor("#E8890C")
GREY = colors.HexColor("#6B7280")
LIGHT = colors.HexColor("#F3F4F6")
CALLOUT_BG = colors.HexColor("#FFF4E6")
CALLOUT_BORDER = colors.HexColor("#E8890C")
GUARD_BG = colors.HexColor("#FDECEC")
GUARD_BORDER = colors.HexColor("#DC2626")

# ---------------------------------------------------------------------------
# Mermaid diagram sources
# ---------------------------------------------------------------------------
DIAGRAMS: dict[str, str] = {
    "highlevel": """flowchart TB
    FL["Flutter App (Android/iOS)"] -->|HTTPS / REST + JWT| API
    subgraph API["FastAPI Route Layer (thin controllers)"]
      direction LR
      R1[auth] --- R2[companies] --- R3[predictions] --- R4[network]
      R5[scenario] --- R6[portfolio] --- R7[explain] --- R8[language] --- R9[voice]
    end
    API --> ENG["Risk Engine: features, graph, GNN, analytics, XAI"]
    ENG --> PG[(PostgreSQL)]
    ENG --> NEO[(Neo4j)]
    ENG -. demo .-> SYN[[Synthetic Economy]]
""",
    "why_graph": """flowchart LR
    SA["Supplier A - distressed"] -->|48% of purchases| X["Company X"]
    SB["Supplier B - healthy"] --> X
    X -->|30% of revenue| CC["Customer C"]
    X --> SD["Subsidiary D - high debt"]
    X --> BK["Bank E - rising exposure"]
""",
    "mobile": """flowchart TB
    START(["Analyst opens app"]) --> AUTH{"JWT stored?"}
    AUTH -- no --> LOGIN[Login]
    AUTH -- yes --> SHELL["Home Shell"]
    LOGIN --> SHELL
    SHELL --> DASH[Dashboard] --> COMP[Company]
    COMP --> NETG[Network Graph]
    COMP --> SCEN[Scenario]
    COMP --> XAI[Explainability]
    SHELL --> ALERTS[Alerts]
    SHELL --> PORT[Portfolio]
    SHELL --> VOICE[Voice]
""",
    "engine": """flowchart TB
    INIT["RiskEngine init"] --> GEN[generate economy]
    GEN --> FEAT[feature frame]
    FEAT --> GRAPH["build graph: X, edge_index, y"]
    GRAPH --> TRAIN[train graph model]
    TRAIN --> PROBA[cache probabilities]
    PROBA --> M1[predict / horizons / health]
    PROBA --> M2[contagion / centrality]
    PROBA --> M3[scenario / simulate failure]
    PROBA --> M4[portfolio / peers / explain]
""",
    "ml_pipeline": """flowchart LR
    A["1. Synthetic economy"] --> B["2. Feature engineering"]
    B --> C["3. Graph construction"]
    C --> D["4. Structural features"]
    D --> E["5. Baselines: LogReg, RF, XGBoost"]
    D --> F["6. GNNs: GCN, GraphSAGE, GAT"]
    E --> G["7. Evaluate: PR-AUC, recall"]
    F --> G
""",
    "models": """flowchart TB
    X["node features + typed edge_index"] --> BASE
    X --> GNN
    subgraph BASE["Baselines (own features only)"]
      AZ[Altman Z-1968] --- LR[LogReg] --- RF[RandomForest] --- XGB[XGBoost]
    end
    subgraph GNN["Graph message passing"]
      GCN[GCN] --- SAGE[GraphSAGE] --- GAT[GAT] --- RGCN[R-GCN relational]
    end
    GNN --> HYB[Hybrid: graph emb + tabular -> GBDT]
    GNN --> HEAD["heads: distress + 3/6/12/24m"]
""",
    "xai": """flowchart LR
    PRED["Distress = 78%"] --> WHY{Explain}
    WHY --> TAB["Feature drivers (SHAP-style):
    +debt growth, +falling OCF, -revenue growth"]
    WHY --> NET["Network drivers:
    Company B supplier elevated,
    Company C customer elevated"]
""",
    "voice": """flowchart LR
    SPEAK["User speaks"] --> STT["/voice/stt"]
    STT --> UND["parse intent + company id"]
    UND --> ENG["Risk Engine answer"]
    ENG --> TR["translate to user language"]
    TR --> TTS["/voice/tts"]
    TTS --> HEAR["User hears answer"]
""",
    "data": """flowchart LR
    subgraph PG["PostgreSQL - structured"]
      U[users] --- CO[companies] --- FS[financials]
      PRp[predictions] --- AL[alerts] --- PO[portfolios]
    end
    subgraph NEO["Neo4j - relationships"]
      N1[SUPPLIES] --- N2[CUSTOMER_OF] --- N3[OWNS]
      N4[BORROWS_FROM] --- N5[SAME_INDUSTRY]
    end
""",
    "deploy": """flowchart LR
    SRC[Source] --> BUILD["Docker multi-stage build"]
    BUILD --> IMG["kavach-api image"]
    IMG --> RUN["Render / Docker host"]
    RUN --> HC["/api/health"]
    PG[(Managed Postgres)] --> RUN
    NEO[(Neo4j Aura)] --> RUN
    IMG --> APK["Flutter -> APK"]
""",
    "master": """flowchart TB
    P(["PROBLEM: companies fail via their network,
    not just their balance sheet"]) --> PROD["PRODUCT: Kavach"]
    PROD --> UI["Flutter App"]
    UI --> API["FastAPI Routes (thin)"]
    API --> ENG["Risk Engine (GNN + analytics + XAI)"]
    ENG --> DATA["PostgreSQL + Neo4j / synthetic"]
    ENG -.-> MODELS["GCN, GraphSAGE, GAT vs LogReg, RF, XGBoost"]
""",
}


def render_diagrams() -> dict[str, Path]:
    cfgf = Path(tempfile.gettempdir()) / "mmdc_puppeteer.json"
    cfgf.write_text(json.dumps({"args": ["--no-sandbox", "--disable-setuid-sandbox"]}))
    env = os.environ.copy()
    if "PUPPETEER_EXECUTABLE_PATH" not in env:
        for cand in [
            "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
            "/usr/bin/chromium", "/usr/bin/chromium-browser", "/usr/bin/google-chrome-stable",
        ]:
            if Path(cand).exists():
                env["PUPPETEER_EXECUTABLE_PATH"] = cand
                break
    out = {}
    for name, src in DIAGRAMS.items():
        mmd = DIAG / f"{name}.mmd"
        png = DIAG / f"{name}.png"
        mmd.write_text(src)
        subprocess.run(
            ["mmdc", "-i", str(mmd), "-o", str(png), "-b", "white", "-s", "3",
             "-p", str(cfgf)],
            check=True, env=env, capture_output=True,
        )
        out[name] = png
    return out


# ---------------------------------------------------------------------------
# Styles
# ---------------------------------------------------------------------------
def styles():
    ss = getSampleStyleSheet()
    S = {}
    S["title"] = ParagraphStyle("t", parent=ss["Title"], fontSize=34, textColor=NAVY,
                                spaceAfter=14, alignment=TA_CENTER, leading=40)
    S["subtitle"] = ParagraphStyle("st", parent=ss["Normal"], fontSize=15, textColor=GREY,
                                   alignment=TA_CENTER, leading=20, spaceAfter=6)
    S["h1num"] = ParagraphStyle("h1n", parent=ss["Heading1"], fontSize=19, textColor=ORANGE)
    S["h1"] = ParagraphStyle("h1", parent=ss["Heading1"], fontSize=19, textColor=NAVY,
                             spaceBefore=8, spaceAfter=8)
    S["h2"] = ParagraphStyle("h2", parent=ss["Heading2"], fontSize=13.5, textColor=BLUE,
                             spaceBefore=10, spaceAfter=4)
    S["body"] = ParagraphStyle("b", parent=ss["Normal"], fontSize=10.3, leading=15,
                               spaceAfter=6, alignment=TA_LEFT, textColor=colors.HexColor("#1F2937"))
    S["bullet"] = ParagraphStyle("bl", parent=S["body"], leftIndent=14, bulletIndent=4,
                                 spaceAfter=3)
    S["caption"] = ParagraphStyle("cap", parent=ss["Italic"], fontSize=9, textColor=GREY,
                                  alignment=TA_CENTER, spaceBefore=4, spaceAfter=12)
    S["callout"] = ParagraphStyle("co", parent=ss["Normal"], fontSize=9.6, leading=14,
                                  textColor=colors.HexColor("#7A4B00"))
    S["guard"] = ParagraphStyle("gu", parent=ss["Normal"], fontSize=9.6, leading=14,
                               textColor=colors.HexColor("#7F1D1D"))
    S["qq"] = ParagraphStyle("q", parent=S["body"], fontSize=10.5, textColor=NAVY,
                             spaceBefore=8, spaceAfter=2)
    S["toc"] = ParagraphStyle("toc", parent=S["body"], fontSize=11, leading=20)
    S["cover_li"] = ParagraphStyle("cli", parent=ss["Normal"], fontSize=10.5, leading=17,
                                   alignment=TA_CENTER, textColor=colors.HexColor("#374151"))
    return S


# ---------------------------------------------------------------------------
# Flowable helpers
# ---------------------------------------------------------------------------
def diagram(png: Path, caption: str, S, max_w=16 * cm, max_h=11 * cm):
    from PIL import Image as PILImage
    w, h = PILImage.open(png).size
    ratio = min(max_w / w, max_h / h)
    img = Image(str(png), width=w * ratio, height=h * ratio)
    img.hAlign = "CENTER"
    return KeepTogether([Spacer(1, 4), img, Paragraph(caption, S["caption"])])


def callout(text: str, S, guard=False):
    style = S["guard"] if guard else S["callout"]
    bg = GUARD_BG if guard else CALLOUT_BG
    border = GUARD_BORDER if guard else CALLOUT_BORDER
    label = "Guardrail: " if guard else ""
    p = Paragraph(f"<b>{label}</b>{text}", style)
    t = Table([[p]], colWidths=[16 * cm])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), bg),
        ("BOX", (0, 0), (-1, -1), 1, border),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
    ]))
    return KeepTogether([Spacer(1, 4), t, Spacer(1, 8)])


def section(n: int, title: str, S):
    tbl = Table([[Paragraph(str(n), S["h1num"]), Paragraph(title, S["h1"])]],
                colWidths=[1.1 * cm, 15 * cm])
    tbl.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LINEBELOW", (0, 0), (-1, -1), 1.2, colors.HexColor("#E5E7EB")),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 10),
    ]))
    return KeepTogether([Spacer(1, 6), tbl, Spacer(1, 8)])


def bullets(items, S):
    return [Paragraph(f"• {it}", S["bullet"]) for it in items]


# ---------------------------------------------------------------------------
# Page furniture
# ---------------------------------------------------------------------------
def footer(canvas, doc):
    canvas.saveState()
    canvas.setFont("Helvetica", 8)
    canvas.setFillColor(GREY)
    canvas.drawString(2 * cm, 1.2 * cm, "Kavach — System Architecture & Engineering Guide")
    canvas.drawRightString(A4[0] - 2 * cm, 1.2 * cm, f"Page {doc.page}")
    canvas.setStrokeColor(colors.HexColor("#E5E7EB"))
    canvas.line(2 * cm, 1.6 * cm, A4[0] - 2 * cm, 1.6 * cm)
    canvas.restoreState()


def build():
    D = render_diagrams()
    S = styles()
    story = []

    # ---- cover ----
    story += [Spacer(1, 4.5 * cm),
              Paragraph("KAVACH", S["title"]),
              Paragraph("Detailed System Architecture &amp; Engineering Guide", S["subtitle"]),
              Paragraph("Graph Neural Network Corporate Financial Risk Intelligence Platform",
                        S["subtitle"]),
              Spacer(1, 0.5 * cm)]
    hr = Table([[""]], colWidths=[6 * cm], rowHeights=[3])
    hr.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), ORANGE)]))
    hr.hAlign = "CENTER"
    story += [hr, Spacer(1, 0.8 * cm)]
    for line in [
        "15 architecture diagrams, broken down by subsystem",
        "Mobile · Backend · Risk Engine · ML pipeline · Graph data model",
        "Explainable AI · Network contagion · Scenario &amp; portfolio",
        "Voice &amp; multilingual pipeline · Security · Deployment",
        "Grounded in 20+ research papers (see docs/RESEARCH.md)",
        "Rapid-fire Q&amp;A and “claims to avoid” guardrails",
    ]:
        story.append(Paragraph("● " + line, S["cover_li"]))
    story += [Spacer(1, 1.4 * cm),
              Paragraph("Built from the project source. Read top to bottom once, then use the "
                        "diagrams as recall anchors.", S["cover_li"]),
              PageBreak()]

    # ---- contents ----
    story += [Paragraph("Contents", S["h1"]), Spacer(1, 6)]
    toc = [
        "What Kavach Is", "System at a Glance — High-Level Architecture",
        "The Core Insight — Why a Graph", "Mobile-Side Architecture",
        "Backend / API Layer", "The Risk Engine — Inference &amp; Analytics Core",
        "ML Pipeline — Data → Features → Graph → Models",
        "The Models — Baselines vs GCN / GraphSAGE / GAT",
        "Handling Class Imbalance", "Explainable AI — Feature &amp; Network Attribution",
        "Network Analytics — Contagion, Centrality, Simulation",
        "Scenario &amp; Portfolio Intelligence", "Data Model — PostgreSQL + Neo4j",
        "Voice &amp; Multilingual Pipeline", "Security &amp; Resilience", "Deployment",
        "Trade-offs &amp; Known Weaknesses", "Interview Mental Model (Master Diagram)",
        "Claims to Avoid Unless Verified in Code", "API Route Catalog", "Rapid-Fire Q&amp;A",
    ]
    rows = [[Paragraph(f"<b>{i+1}</b>", S["toc"]), Paragraph(t, S["toc"])]
            for i, t in enumerate(toc)]
    tt = Table(rows, colWidths=[1.2 * cm, 15 * cm])
    tt.setStyle(TableStyle([("LINEBELOW", (0, 0), (-1, -1), 0.4, colors.HexColor("#EEEEEE")),
                            ("TOPPADDING", (0, 0), (-1, -1), 5),
                            ("BOTTOMPADDING", (0, 0), (-1, -1), 5)]))
    story += [tt, PageBreak()]

    B = lambda t: Paragraph(t, S["body"])   # noqa: E731
    H2 = lambda t: Paragraph(t, S["h2"])    # noqa: E731

    # 1
    story += [section(1, "What Kavach Is", S),
              B("Kavach (Sanskrit for <i>shield</i>) is a <b>Corporate Financial Risk "
                "Intelligence Platform</b> that predicts corporate <b>financial distress</b> — "
                "the state preceding default, restructuring, insolvency and bankruptcy — using "
                "<b>Graph Neural Networks</b>. Its defining idea: a company's risk cannot be read "
                "from its balance sheet alone; it depends on the health of the companies it is "
                "connected to (suppliers, customers, subsidiaries, lenders, peers)."),
              H2("Core capabilities")]
    story += bullets([
        "Distress probability + risk band (LOW / MODERATE / HIGH / CRITICAL)",
        "Multi-horizon prediction (3 / 6 / 12 / 24 months)",
        "Network contagion, centrality, supplier/customer concentration",
        "Explainable AI — feature drivers AND which connected companies drove the score",
        "Scenario stress testing and supplier-failure network simulation",
        "Portfolio distress exposure with shared-network concentration",
        "Early-warning alerts, industry risk heatmap, multilingual voice assistant",
    ], S)
    story += [H2("Technology stack")]
    story += bullets([
        "<b>Mobile:</b> Flutter + Dart, Provider, Dio, fl_chart, graphview",
        "<b>Backend:</b> FastAPI (thin routers) → Risk Engine → Postgres / Neo4j",
        "<b>ML:</b> PyTorch + PyTorch Geometric (GCN/GraphSAGE/GAT); scikit-learn + XGBoost",
        "<b>Explainability:</b> SHAP, GNNExplainer / PGExplainer, GAT attention",
        "<b>Infra:</b> Docker, docker-compose, GitHub Actions, Render / Neo4j Aura",
    ], S)

    # 2
    story += [section(2, "System at a Glance — High-Level Architecture", S),
              B("Four layers: a <b>Flutter client</b> talks to a <b>FastAPI route layer</b>, "
                "which delegates to a <b>Risk Engine</b> owning all modelling and analytics, "
                "which reads from <b>PostgreSQL + Neo4j</b> (or a self-contained synthetic "
                "economy in demo mode)."),
              diagram(D["highlevel"], "Diagram 1 — High-level system architecture: "
                      "client → routes → engine → data.", S),
              B("<b>Narration:</b> route handlers stay thin and delegate to one Risk Engine that "
                "owns modelling and graph analytics. The engine reads financials from Postgres "
                "and relationships from Neo4j; in demo mode it builds a synthetic economy so the "
                "whole system runs with zero external services.")]

    # 3
    story += [section(3, "The Core Insight — Why a Graph", S),
              B("A tabular model sees only one company's own numbers; it cannot see that a "
                "healthy company's biggest supplier is collapsing. Kavach models the economy as "
                "a graph and uses <b>message passing</b> so each prediction is informed by its "
                "neighbourhood."),
              diagram(D["why_graph"], "Diagram 2 — A healthy-looking company inside an unhealthy "
                      "network.", S, max_h=7 * cm),
              B("<b>Message passing:</b> each company starts as its own feature vector; at each "
                "GNN layer it aggregates neighbours' vectors and updates its own. After two "
                "layers a company's embedding encodes its 1–2 hop neighbourhood, which a "
                "classifier head turns into a distress probability."),
              callout("Don't claim Kavach connects to live real-world supply-chain feeds. The "
                      "shipped system runs on a synthetic economy and is designed to accept real "
                      "Postgres/Neo4j sources.", S, guard=True)]

    # 4
    story += [section(4, "Mobile-Side Architecture", S),
              B("The Flutter app is a bottom-nav shell hosting workflow modes; each screen calls "
                "thin API routes through a single ApiClient."),
              diagram(D["mobile"], "Diagram 3 — Mobile navigation and screen-to-API mapping.", S),
              H2("Talking points")]
    story += bullets([
        "State in a ChangeNotifier (AppState): auth token, current user, selected locale.",
        "JWT persisted in flutter_secure_storage; attached as a Bearer header by ApiClient.",
        "Network graph screen renders the ego graph with graphview, coloured by risk band.",
        "Localisation via Flutter ARB files (en/hi/ta), switchable at runtime from Settings.",
    ], S)

    # 5
    story += [section(5, "Backend / API Layer", S),
              B("A thin-controller FastAPI app: routers validate input and delegate to the Risk "
                "Engine; they contain no modelling logic."),
              diagram(D["engine"], "Diagram 4 — Risk Engine initialisation and method surface.",
                      S),
              H2("Talking points")]
    story += bullets([
        "get_engine() is an lru_cache singleton — the model trains once per process.",
        "Auth is JWT (HS256) via python-jose; passwords hashed with pbkdf2_sha256.",
        "Postgres and Neo4j layers are optional (is_configured guards); unset ⇒ synthetic.",
        "Heavy routes degrade gracefully; the API is designed never to hard-fail a request.",
    ], S)

    # 6
    story += [section(6, "The Risk Engine — Inference & Analytics Core", S),
              B("kavach_ml.serve.engine.RiskEngine is the heart of the system. On first use it "
                "generates the economy, builds the graph, trains the graph model, and caches "
                "predictions. Every product feature is a method on this class, guaranteeing all "
                "endpoints return numbers consistent with the same model and graph.")]

    # 7
    story += [section(7, "ML Pipeline — Data → Features → Graph → Models", S),
              diagram(D["ml_pipeline"], "Diagram 5 — End-to-end ML pipeline.", S, max_h=6 * cm),
              B("<b>Leakage-free experiment:</b> the model's node features are a company's OWN "
                "financial ratios only. Graph structure reaches the GNN through edge_index "
                "message passing — not by injecting neighbour features into the tabular vector. "
                "Structural scalars (concentration, centrality) are kept separate for analytics "
                "and explainability, so the tabular-vs-graph comparison is fair."),
              B("The synthetic economy encodes distress from a company's own fundamentals AND its "
                "neighbours' health, plus explicit <b>network-induced distress</b> (healthy firms "
                "that fail because ≥2 direct counterparties fail) — the signal only a graph model "
                "can capture.")]

    # 8
    story += [section(8, "The Models — Baselines vs GCN / GraphSAGE / GAT", S),
              diagram(D["models"], "Diagram 6 — Tabular baselines vs graph models, shared "
                      "prediction heads.", S),
              ]
    story += bullets([
        "<b>GCN:</b> degree-normalised neighbour averaging — a strong, simple baseline.",
        "<b>GraphSAGE:</b> samples and aggregates neighbours; scales to large graphs.",
        "<b>GAT:</b> learns attention weights, so a big supplier counts more than a tiny one; "
        "attention doubles as an explanation signal.",
        "<b>R-GCN (relational):</b> a separate transformation per relation type — the frontier "
        "model; tops the scoreboard on PR-AUC / KS.",
        "<b>Hybrid GNN + GBDT:</b> graph embedding + tabular features into a boosted tree — the "
        "SOTA recipe at scale (Relational-GNN paper, 2026).",
    ], S)
    story += [B("Grounded in the literature (R-GCN, Schlichtkrull 2018; HGNN-EBP 2025; relational "
                "GNN + ensemble 2026 — see docs/RESEARCH.md). The repo ships production PyTorch "
                "Geometric models (GCN/GraphSAGE/GAT/RGCN), a NumPy reference GNN (SGC + "
                "relational + hybrid) that runs anywhere, and the classic Altman Z-Score (1968) "
                "baseline. Metrics follow the credit-risk literature: PR-AUC, KS, recall, "
                "precision@k."),
              callout("Don't over-claim the hybrid GNN+GBDT — it wins at scale (millions of "
                      "nodes); on a few hundred synthetic nodes it under-fits versus a linear "
                      "head. Report the regime honestly.", S, guard=True)]

    # 9
    story += [section(9, "Handling Class Imbalance", S),
              B("Distress is the rare class, so accuracy is not a headline metric. The pipeline "
                "uses class weighting + focal loss on the GNN, scale_pos_weight for XGBoost, "
                "threshold tuning on validation, and PR-AUC / recall as the metrics that lead the "
                "scoreboard."),
              callout("Describe this as per-model class weighting + focal loss + threshold "
                      "tuning — not a full cost-sensitive learning framework, unless you extend "
                      "it into one.", S, guard=True)]

    # 10
    story += [section(10, "Explainable AI — Feature & Network Attribution", S),
              B("Kavach never shows a bare “78%”. It answers why."),
              diagram(D["xai"], "Diagram 7 — Two explanation channels: feature drivers and "
                      "network drivers.", S, max_h=7 * cm)]
    story += bullets([
        "<b>Tabular:</b> SHAP when available; a fast linear/importance fallback otherwise. "
        "Signed per-feature contributions + normalised share.",
        "<b>Graph:</b> ranks neighbours by influence = edge_weight × neighbour risk; with a "
        "trained GAT, reads attention weights or runs GNNExplainer.",
        "API can localise driver labels (e.g. /api/explain/{id}?lang=hi).",
    ], S)

    # 11
    story += [section(11, "Network Analytics — Contagion, Centrality, Simulation", S)]
    story += bullets([
        "<b>Contagion:</b> how exposed a firm is to distressed neighbours.",
        "<b>Centrality:</b> PageRank (power iteration) + degree — systemically important firms.",
        "<b>Concentration:</b> Herfindahl-Hirschman Index over supplier / customer edge weights.",
        "<b>What-if simulation:</b> simulate_failure propagates a collapse downstream with "
        "distance decay, returning the affected set + an impact level.",
    ], S)

    # 12
    story += [section(12, "Scenario & Portfolio Intelligence", S),
              B("<b>Scenario / stress test:</b> recompute risk under a revenue shock, rate change "
                "and/or supplier failure — a closed-form perturbation of the base probability, "
                "with the supplier-failure term scaled by supplier concentration."),
              B("<b>Portfolio risk:</b> weight-average holdings' distress probabilities into one "
                "exposure, then surface shared-network concentration — e.g. “42% of your "
                "portfolio is linked to the same high-risk supplier network” — a graph-native "
                "insight a per-name model cannot produce.")]

    # 13
    story += [section(13, "Data Model — PostgreSQL + Neo4j", S),
              diagram(D["data"], "Diagram 8 — Two stores: structured financials (Postgres) and "
                      "relationships (Neo4j).", S, max_h=7 * cm),
              B("Postgres holds users, companies, financial_statements, predictions (per-horizon "
                "columns), alerts, portfolios (JSONB) and a model_versions registry. Neo4j holds "
                "the relationship graph the GNN consumes; the 1-hop Cypher query feeds both the "
                "graph screen and the graph builder."),
              callout("Don't claim a relational DB was “rejected because it can't scale”. The "
                      "honest framing: financials are tabular (Postgres), relationships are a "
                      "graph (Neo4j), each used for its strength.", S, guard=True)]

    # 14
    story += [section(14, "Voice & Multilingual Pipeline", S),
              diagram(D["voice"], "Diagram 9 — Voice loop: speak → STT → answer → translate → "
                      "TTS → hear.", S, max_h=6.5 * cm)]
    story += bullets([
        "STT: stub / Whisper / Azure / Google. TTS: stub / gTTS / Azure / Google — both degrade "
        "gracefully (stub returns valid silent WAV / echo).",
        "/api/voice/ask runs the full loop: transcribe → parse company id → answer → translate "
        "→ speak.",
        "12 Indian languages via /api/language/supported; UI localised through Flutter ARB "
        "files; translation service falls back builtin-glossary → passthrough.",
    ], S)

    # 15
    story += [section(15, "Security & Resilience", S)]
    story += bullets([
        "JWT (HS256), Bearer tokens, hashed passwords (pbkdf2_sha256).",
        "Pydantic input validation on every request body; bounded query params.",
        "Fail-soft: optional providers and databases degrade to safe defaults; the synthetic "
        "engine guarantees the API works standalone.",
        "CORS configurable; secrets via environment; /api/health for orchestrators.",
    ], S)
    story += [callout("The shipped auth store is in-memory with a seeded demo user; describe it "
                      "as a JWT flow ready to be backed by Postgres/Firebase, not a hardened "
                      "identity system.", S, guard=True)]

    # 16
    story += [section(16, "Deployment", S),
              diagram(D["deploy"], "Diagram 10 — Build-to-deploy pipeline.", S, max_h=6.5 * cm)]
    story += bullets([
        "Backend image: backend/Dockerfile multi-stage build; Uvicorn + /api/health HEALTHCHECK.",
        "Full local stack: docker compose up --build (Postgres + Neo4j + API).",
        "Managed deploy: render.yaml provisions web service + managed Postgres; Neo4j via Aura.",
        "Mobile: flutter build apk --release --dart-define=KAVACH_API_BASE=…",
        "CI/CD: GitHub Actions runs ML tests + comparison, API tests, Docker build, Flutter "
        "analyze.",
    ], S)

    # 17
    story += [section(17, "Trade-offs & Known Weaknesses", S),
              B("Being candid here is a strong engineering signal.")]
    story += bullets([
        "Default uses the NumPy reference GNN for portability; full PyG GCN/GraphSAGE/GAT needs "
        "torch installed.",
        "Data is synthetic; no real-data ETL in the repo yet (pipeline is source-agnostic).",
        "Auth user store is in-memory; should be Postgres/Firebase-backed for production.",
        "Scenario recomputation is a closed-form approximation, not full GNN re-inference.",
        "Contagion / failure simulation use heuristic decay, not a calibrated cascade model.",
        "No temporal modelling yet (temporal GNN is on the roadmap).",
    ], S)

    # 18
    story += [section(18, "Interview Mental Model (Master Diagram)", S),
              B("Explain this one diagram and zoom into any box on a follow-up, and you can "
                "navigate almost any Kavach architecture question."),
              diagram(D["master"], "Diagram 11 — problem → product → app → API → engine → data.",
                      S)]

    # 19
    story += [section(19, "Claims to Avoid Unless Verified in Code", S)]
    story += bullets([
        "Don't claim live real-world data ingestion — it runs on a synthetic economy.",
        "Don't claim a relational DB was rejected for scale — each store is used for its "
        "strength.",
        "Don't claim the PyTorch GAT trains by default — the portable default is the NumPy GNN.",
        "Don't claim a production-grade identity system — auth is a JWT flow + seeded user store.",
        "Don't invent exact accuracy figures — quote the reproducible quick_demo.py scoreboard.",
    ], S)

    # 20
    story += [section(20, "API Route Catalog", S)]
    routes = [
        ("Auth", "POST /api/auth/register · POST /api/auth/login"),
        ("Companies", "GET /api/companies · /companies/search · /companies/{id}"),
        ("Predictions", "GET /api/predictions/{id} · /multi-horizon · /health-score"),
        ("Network", "GET /network/{id}/graph · /contagion · POST /simulate-failure · GET /heatmap"),
        ("Scenario", "POST /api/scenario · GET /api/scenario/{id}/sweep"),
        ("Portfolio", "POST /api/portfolio/risk"),
        ("Explain / Alerts", "GET /api/explain/{id}?lang= · GET /api/alerts/early-warning"),
        ("Language / Voice", "GET /language/supported · POST /language/translate · /voice/tts · "
                             "/voice/stt · /voice/ask"),
        ("Ops", "GET /api/ml/model-comparison · /api/ml/dataset-summary · /api/health"),
    ]
    rows = [[Paragraph(f"<b>{g}</b>", S["body"]), Paragraph(r, S["body"])] for g, r in routes]
    rt = Table(rows, colWidths=[3.6 * cm, 12.4 * cm])
    rt.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (0, -1), LIGHT),
        ("LINEBELOW", (0, 0), (-1, -1), 0.4, colors.HexColor("#E5E7EB")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 6), ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
    ]))
    story += [rt]

    # 21
    story += [section(21, "Rapid-Fire Q&A", S)]
    qa = [
        ("In one sentence, what is Kavach?",
         "A corporate financial-distress prediction platform that uses Graph Neural Networks to "
         "model supplier/customer/ownership/lending relationships, so a company's risk reflects "
         "its whole network — delivered as a Flutter app over FastAPI + Postgres + Neo4j."),
        ("Why a GNN instead of XGBoost?",
         "Tabular models see only a company's own financials; a GNN passes messages along "
         "relationship edges and captures contagion. We train both and show the graph model wins "
         "on PR-AUC and recall."),
        ("How do you prove the graph actually helps?",
         "Same stratified split for every model; node features are own-financials only; graph "
         "reaches the GNN via message passing, not injected features. Synthetic labels include "
         "network-induced distress tabular models can't capture; the scoreboard shows GraphSAGE/"
         "GCN topping PR-AUC."),
        ("How do you handle class imbalance?",
         "Class weighting + focal loss on the GNN, scale_pos_weight for XGBoost, threshold tuned "
         "on validation, and PR-AUC / recall as headline metrics — never raw accuracy."),
        ("What is GAT and why does it matter?",
         "Graph Attention Network learns how much weight to give each neighbour, so a big "
         "supplier counts more than a tiny one; the attention weights explain which connected "
         "company drove the risk."),
        ("Why two databases?",
         "Financials are naturally tabular (Postgres); relationships are naturally a graph "
         "(Neo4j). Each store does what it is best at."),
        ("What happens if a provider or DB is down?",
         "Everything degrades to safe defaults — stub audio, glossary/passthrough translation, "
         "synthetic engine — so the API never hard-fails. Fail-soft is deliberate."),
        ("What would you improve first with more time?",
         "Real-data ETL into Postgres/Neo4j, move auth to a persistent store, a temporal GNN for "
         "evolving relationships, and true scenario re-inference under perturbed inputs."),
    ]
    for q, a in qa:
        story += [Paragraph(f"<b>Q.</b> {q}", S["qq"]),
                  Paragraph(f"<b>A.</b> {a}", S["body"])]

    doc = BaseDocTemplate(str(OUT), pagesize=A4,
                          leftMargin=2 * cm, rightMargin=2 * cm,
                          topMargin=1.8 * cm, bottomMargin=2 * cm)
    frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="main")
    doc.addPageTemplates([PageTemplate(id="all", frames=[frame], onPage=footer)])
    doc.build(story)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    build()

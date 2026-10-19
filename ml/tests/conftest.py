import os

# Unit tests use the fast interpretable member; test_gnn_suite exercises PyG explicitly.
os.environ.setdefault("KAVACH_MODELS", "irgnn")

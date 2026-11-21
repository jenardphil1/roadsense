"""Freeze Optimized v2 tensor signatures; weights and operators are unchanged.

Run from the repository root with numpy and flatbuffers installed. Validate
output parity and device delegate support before shipping a regenerated asset.
"""
from pathlib import Path
import sys
import flatbuffers

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'opt'))
from schema_generated import Model, ModelT

assets = Path(__file__).resolve().parents[1] / 'assets/dpwh_thesis_optimized'
model = ModelT.InitFromObj(Model.GetRootAsModel((assets / 'best_float32.tflite').read_bytes(), 0))
for graph in model.subgraphs:
    for tensor in graph.tensors:
        tensor.shapeSignature = tensor.shape
builder = flatbuffers.Builder(0)
root = model.Pack(builder)
builder.Finish(root, b'TFL3')
(assets / 'best_static_float32.tflite').write_bytes(builder.Output())

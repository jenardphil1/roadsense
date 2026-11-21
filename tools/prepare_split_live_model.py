"""Partition Optimized v2 before its output transposes; preserve weights/ops.

The convolution graph can use the Android GPU delegate, while the small
transpose/DFL decoding graph runs on CPU. Verify outputs before shipping.
"""
from copy import deepcopy
from pathlib import Path
import sys

import flatbuffers
import numpy as np

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'opt'))
from schema_generated import Model, ModelT, BuiltinOperator

assets = root / 'assets/dpwh_thesis_optimized'
source = ModelT.InitFromObj(Model.GetRootAsModel((assets / 'best_float32.tflite').read_bytes(), 0))
graph = source.subgraphs[0]
producer = {int(t): i for i, op in enumerate(graph.operators) for t in op.outputs}
features = []
for op in graph.operators:
    if source.operatorCodes[op.opcodeIndex].builtinCode == BuiltinOperator.TRANSPOSE:
        permutation = np.frombuffer(source.buffers[graph.tensors[op.inputs[1]].buffer].data, dtype=np.int32)
        if permutation.tolist() == [0, 3, 1, 2]:
            features.append(int(op.inputs[0]))
if len(features) != 6:
    raise ValueError('Expected three box and three class feature tensors.')


def export(name, inputs, outputs):
    boundaries = set(map(int, inputs))
    selected = set()

    def visit(tensor):
        if tensor in boundaries or tensor not in producer:
            return
        index = producer[tensor]
        if index in selected:
            return
        selected.add(index)
        for dependency in graph.operators[index].inputs:
            if dependency >= 0:
                visit(int(dependency))

    for output in outputs:
        visit(int(output))
    result = deepcopy(source)
    part = result.subgraphs[0]
    part.operators = [part.operators[i] for i in sorted(selected)]
    used = sorted(boundaries | set(map(int, outputs)) |
                  {int(t) for op in part.operators for t in (*op.inputs, *op.outputs) if t >= 0})
    remap = {old: new for new, old in enumerate(used)}
    part.tensors = [part.tensors[i] for i in used]
    buffers = sorted({0} | {t.buffer for t in part.tensors})
    buffer_map = {old: new for new, old in enumerate(buffers)}
    result.buffers = [result.buffers[i] for i in buffers]
    for tensor in part.tensors:
        tensor.buffer = buffer_map[tensor.buffer]
        tensor.shapeSignature = tensor.shape
    for op in part.operators:
        op.inputs = np.array([remap[int(t)] if t >= 0 else -1 for t in op.inputs], dtype=np.int32)
        op.outputs = np.array([remap[int(t)] for t in op.outputs], dtype=np.int32)
        if op.intermediates is not None and len(op.intermediates):
            raise ValueError('Unexpected intermediate tensors; review partitioning.')
    part.inputs = np.array([remap[int(t)] for t in inputs], dtype=np.int32)
    part.outputs = np.array([remap[int(t)] for t in outputs], dtype=np.int32)
    result.metadata = []
    result.metadataBuffer = []
    result.signatureDefs = []
    builder = flatbuffers.Builder(0)
    packed = result.Pack(builder)
    builder.Finish(packed, b'TFL3')
    (assets / name).write_bytes(builder.Output())
    print(f'{name}: {len(part.operators)} operators; {len(builder.Output())} bytes')


export('live_backbone.tflite', graph.inputs, features)
export('live_head.tflite', features, graph.outputs)

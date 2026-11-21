"""Compare the mobile model and its static-signature export on six sample inputs.

These annotated sample pictures check export parity, not detection accuracy.
Requires ai-edge-litert, numpy and Pillow. Run from the repository root.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps
from ai_edge_litert.interpreter import Interpreter

root = Path(__file__).resolve().parents[1]
models = root / 'assets/dpwh_thesis_optimized'
interpreters = [Interpreter(model_path=str(models / name), num_threads=2)
                for name in ('best_float32.tflite', 'best_static_float32.tflite')]
for interpreter in interpreters:
    interpreter.allocate_tensors()
backbone = Interpreter(model_path=str(models / 'live_backbone.tflite'), num_threads=2)
head = Interpreter(model_path=str(models / 'live_head.tflite'), num_threads=2)
backbone.allocate_tensors()
head.allocate_tensors()

samples = sorted((root / 'DPWH_Thesis_and_App_Package (6)' /
                  'sample_test_predictions').glob('*.jpg'))[:6]
if len(samples) != 6:
    raise RuntimeError('Six sample images are required for this parity check.')

for sample in samples:
    outputs = []
    for interpreter in interpreters:
        info = interpreter.get_input_details()[0]
        _, height, width, _ = info['shape']
        with Image.open(sample) as source:
            upright = ImageOps.exif_transpose(source).convert('RGB')
            padded = ImageOps.pad(upright, (int(width), int(height)),
                                  method=Image.Resampling.BILINEAR,
                                  color=(114, 114, 114))
        tensor = np.asarray(padded, dtype=np.float32)[None] / 255.0
        interpreter.set_tensor(info['index'], tensor)
        interpreter.invoke()
        outputs.append(interpreter.get_tensor(interpreter.get_output_details()[0]['index']))
    delta = float(np.max(np.abs(outputs[0] - outputs[1])))
    print(f'{sample.name}: max_absolute_difference={delta}', flush=True)
    np.testing.assert_array_equal(outputs[0], outputs[1])
    backbone.set_tensor(backbone.get_input_details()[0]['index'], tensor)
    backbone.invoke()
    for feature, target in zip(backbone.get_output_details(), head.get_input_details(), strict=True):
        head.set_tensor(target['index'], backbone.get_tensor(feature['index']))
    head.invoke()
    split_output = head.get_tensor(head.get_output_details()[0]['index'])
    print(f'  split max_absolute_difference={np.max(np.abs(outputs[0] - split_output))}', flush=True)
    np.testing.assert_allclose(outputs[0], split_output, rtol=1e-5, atol=1e-6)
print('PASS: six static/split CPU output comparisons; GPU parity requires device checks.')

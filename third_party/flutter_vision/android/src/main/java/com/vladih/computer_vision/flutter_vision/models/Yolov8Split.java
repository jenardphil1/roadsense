package com.vladih.computer_vision.flutter_vision.models;

import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.os.SystemClock;
import android.util.Log;
import org.tensorflow.lite.Interpreter;
import java.io.FileInputStream;
import java.lang.reflect.Array;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Keep output transposes/DFL on CPU and accelerate the convolution graph on GPU. */
public class Yolov8Split extends Yolov8 {
    private final String headPath;
    private Interpreter head;
    private Object[] features;
    private final Map<Integer, Object> featureOutputs = new HashMap<>();
    private final Map<Integer, Object> headOutput = new HashMap<>();

    public Yolov8Split(Context context, String modelPath, int threads, boolean gpu,
                       String labels, int rotation, String headPath) {
        super(context, modelPath, true, threads, false, gpu, labels, rotation);
        this.headPath = headPath;
    }

    @Override
    protected void allocateOutput() throws Exception {
        try (AssetFileDescriptor descriptor = context.getAssets().openFd(headPath);
             FileInputStream stream = new FileInputStream(descriptor.getFileDescriptor())) {
            ByteBuffer model = stream.getChannel().map(FileChannel.MapMode.READ_ONLY,
                    descriptor.getStartOffset(), descriptor.getLength());
            head = new Interpreter(model, new Interpreter.Options().setNumThreads(2).setUseXNNPACK(true));
            head.allocateTensors();
        }
        int count = interpreter.getOutputTensorCount();
        if (count != head.getInputTensorCount()) throw new IllegalArgumentException("Split model feature count mismatch");
        features = new Object[count];
        for (int i = 0; i < count; i++) {
            if (!java.util.Arrays.equals(interpreter.getOutputTensor(i).shape(), head.getInputTensor(i).shape())) {
                throw new IllegalArgumentException("Split model feature shape mismatch at " + i);
            }
            ByteBuffer feature = ByteBuffer.allocateDirect(interpreter.getOutputTensor(i).numBytes()).order(ByteOrder.nativeOrder());
            features[i] = feature;
            featureOutputs.put(i, feature);
        }
        output = (float[][][]) Array.newInstance(float.class, head.getOutputTensor(0).shape());
        headOutput.put(0, output);
        Log.i("Yolo", "Split detector ready: " + count + " feature tensors, CPU output decoding");
    }

    @Override
    public List<Map<String, Object>> detect_task(ByteBuffer input, int sourceHeight, int sourceWidth,
                                                float iou, float confidence, float classThreshold) throws Exception {
        long start = SystemClock.elapsedRealtime();
        try {
            for (Object feature : features) ((ByteBuffer) feature).rewind();
            interpreter.runForMultipleInputsOutputs(new Object[]{input}, featureOutputs);
            long backboneMs = SystemClock.elapsedRealtime() - start;
            for (Object feature : features) ((ByteBuffer) feature).rewind();
            head.runForMultipleInputsOutputs(features, headOutput);
            long headMs = SystemClock.elapsedRealtime() - start - backboneMs;
            int[] shape = interpreter.getInputTensor(0).shape();
            List<float[]> boxes = filter_box(output, iou, confidence, classThreshold, shape[2], shape[1]);
            boxes = restore_size(boxes, shape[2], shape[1], sourceWidth, sourceHeight);
            Log.i("Yolo", "backbone=" + backboneMs + " ms; head=" + headMs + " ms; postprocess="
                    + (SystemClock.elapsedRealtime() - start - backboneMs - headMs) + " ms");
            return out(boxes, labels);
        } finally {
            input.clear();
        }
    }

    @Override
    public void close() {
        try {
            if (head != null) { head.close(); head = null; }
        } finally {
            featureOutputs.clear();
            headOutput.clear();
            features = null;
            super.close();
        }
    }
}

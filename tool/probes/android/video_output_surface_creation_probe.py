"""Run the production VideoOutput Surface lifecycle methods in a host Java fixture."""
import argparse
from pathlib import Path
import subprocess
import sys


HARNESS = r"""
import java.util.*;

public class SurfaceCreationProbe {
  final Object lock = new Object();
  long wid = 123L;
  long surfaceGeneration, lastConsumedTimestamp;
  boolean disposed, disposeComplete, waitUntilFirstFrameRenderedNotify;
  String disposeError;
  final List<MethodChannel.Result> disposeResults = new ArrayList<>();
  final Entry surfaceTextureEntry = new Entry();
  Surface surface;
  final Map<Long, Surface> liveReferences = new HashMap<>();
  final DeleteReference deleteGlobalObjectRef = new DeleteReference();
  final NewReference newGlobalObjectRef = new NewReference();
  final Gate operationGate = new Gate();

  SurfaceCreationProbe() {
    surface = new Surface(surfaceTextureEntry.surfaceTexture());
    liveReferences.put(wid, surface);
  }

  static class OutputOperationToken {}
  static class Gate { void revoke() {} }

  static class Entry {
    final List<Surface> surfaces = new ArrayList<>();
    boolean released, failConstruction, failNewSurfaceRelease;
    Object surfaceTexture() { return this; }
    void release() { released = true; }
  }

  static class Surface {
    boolean released, failRelease;
    Surface(Object value) {
      Entry entry = (Entry) value;
      if (entry.failConstruction) throw new IllegalStateException("injected Surface construction failure");
      failRelease = entry.failNewSurfaceRelease;
      entry.surfaces.add(this);
    }
    void release() {
      if (failRelease) throw new IllegalStateException("injected Surface.release failure");
      released = true;
    }
  }

  class DeleteReference {
    boolean fail;
    int attempts;
    Object invoke(Object unused, long value) {
      attempts++;
      if (fail) throw new IllegalStateException("injected JNI deletion failure");
      liveReferences.remove(value);
      return null;
    }
  }

  class NewReference {
    boolean fail, returnZero;
    int attempts;
    Object invoke(Object unused, Surface value) {
      attempts++;
      if (fail) throw new IllegalStateException("injected JNI allocation failure");
      if (returnZero) return 0L;
      liveReferences.put(456L, value);
      return 456L;
    }
  }

  static class Log { static void i(String tag, String message) {} }
  static class MethodChannel {
    static class Result {
      int successes, errors;
      void success(Object value) { successes++; }
      void error(String code, String message, Object details) { errors++; }
    }
  }

  boolean isCurrentToken(OutputOperationToken token) { return !disposed; }
  void blockResourceSampling() {}
  void transitionSampling(String admission) {}
  void resetFrameSamples() {}
  void finishFrameWait(boolean accepted) {}
  void clearSurface() {}
  void diagnostic(String event, Throwable error) {}

  __CREATE_SURFACE_METHOD__
  __DISPOSE_METHOD__
  __COMPLETE_DISPOSE_METHOD__

  static void check(boolean value, String message) {
    if (!value) throw new AssertionError(message);
  }

  static RuntimeException expectRuntimeException(Runnable action, String message) {
    try {
      action.run();
    } catch (RuntimeException expected) {
      return expected;
    }
    throw new AssertionError(message);
  }

  static void disposeAndCheck(SurfaceCreationProbe output, String scenario) {
    MethodChannel.Result receipt = new MethodChannel.Result();
    output.dispose(receipt);
    check(receipt.successes == 1 && receipt.errors == 0,
        scenario + ": recovered dispose must succeed");
    check(output.wid == 0 && output.liveReferences.isEmpty(),
        scenario + ": dispose must remove every JNI reference");
    check(output.surface == null && output.surfaceTextureEntry.released,
        scenario + ": dispose must release the Surface and texture entry");
    check(output.surfaceTextureEntry.surfaces.stream().allMatch(s -> s.released),
        scenario + ": every allocated Surface must be released");
  }

  static void normalReplacementAndDisposal() {
    SurfaceCreationProbe output = new SurfaceCreationProbe();
    Surface oldSurface = output.surface;
    long oldWid = output.wid;
    long replacement = output.createSurface(new OutputOperationToken());
    check(replacement != 0 && replacement != oldWid, "replacement must receive a new wid");
    check(oldSurface.released && !output.liveReferences.containsKey(oldWid),
        "replacement must release the prior Surface and JNI reference");
    check(output.liveReferences.get(replacement) == output.surface && !output.surface.released,
        "replacement wid must reference the new live Surface");
    disposeAndCheck(output, "normal lifecycle");
  }

  static void surfaceReleaseFailure() {
    SurfaceCreationProbe output = new SurfaceCreationProbe();
    Surface oldSurface = output.surface;
    oldSurface.failRelease = true;
    expectRuntimeException(() -> output.createSurface(new OutputOperationToken()),
        "Surface.release failure must escape createSurface as RuntimeException");
    check(output.wid == 123L && output.liveReferences.size() == 1 &&
        output.liveReferences.get(123L) == oldSurface,
        "Surface.release failure must preserve the old wid and JNI reference");
    check(output.surface == oldSurface && !oldSurface.released &&
        output.surfaceTextureEntry.surfaces.size() == 1 && output.newGlobalObjectRef.attempts == 0,
        "Surface.release failure must stop before creating a replacement");
    oldSurface.failRelease = false;
    disposeAndCheck(output, "Surface.release recovery");
  }

  static void jniDeleteFailure() {
    SurfaceCreationProbe output = new SurfaceCreationProbe();
    Surface oldSurface = output.surface;
    output.deleteGlobalObjectRef.fail = true;
    expectRuntimeException(() -> output.createSurface(new OutputOperationToken()),
        "JNI delete failure must escape createSurface as RuntimeException");
    check(output.wid == 123L && output.liveReferences.size() == 1 &&
        output.liveReferences.get(123L) == oldSurface,
        "JNI delete failure must preserve the old wid and reference");
    check(output.surface == null && oldSurface.released &&
        output.surfaceTextureEntry.surfaces.size() == 1 && output.newGlobalObjectRef.attempts == 0,
        "JNI delete failure must stop before creating a replacement");
    output.deleteGlobalObjectRef.fail = false;
    disposeAndCheck(output, "JNI delete recovery");
  }

  static void simultaneousDeleteAndCreationFailure() {
    SurfaceCreationProbe output = new SurfaceCreationProbe();
    Surface oldSurface = output.surface;
    output.deleteGlobalObjectRef.fail = true;
    output.newGlobalObjectRef.fail = true;
    expectRuntimeException(() -> output.createSurface(new OutputOperationToken()),
        "failed cleanup and replacement must never return the old released wid");
    check(output.wid == 123L && output.liveReferences.size() == 1 &&
        output.liveReferences.get(123L) == oldSurface && oldSurface.released,
        "combined failure must retain the old wid for later disposal");
    check(output.surface == null && output.surfaceTextureEntry.surfaces.size() == 1 &&
        output.newGlobalObjectRef.attempts == 0,
        "combined failure must not attempt replacement creation after failed deletion");
    output.deleteGlobalObjectRef.fail = false;
    output.newGlobalObjectRef.fail = false;
    disposeAndCheck(output, "combined failure recovery");
  }

  static void surfaceConstructionFailure() {
    SurfaceCreationProbe output = new SurfaceCreationProbe();
    output.surfaceTextureEntry.failConstruction = true;
    expectRuntimeException(() -> output.createSurface(new OutputOperationToken()),
        "Surface construction failure must escape createSurface");
    check(output.surface == null && output.wid == 0 && output.liveReferences.isEmpty(),
        "Surface construction failure must leave no published Surface or reference");
    check(output.newGlobalObjectRef.attempts == 0,
        "failed Surface construction must not allocate a JNI reference");
    disposeAndCheck(output, "Surface construction failure");
  }

  static void newReferenceFailure(boolean returnZero) {
    SurfaceCreationProbe output = new SurfaceCreationProbe();
    output.newGlobalObjectRef.fail = !returnZero;
    output.newGlobalObjectRef.returnZero = returnZero;
    expectRuntimeException(() -> output.createSurface(new OutputOperationToken()),
        "failed or zero JNI allocation must escape createSurface");
    check(output.surface == null && output.wid == 0 && output.liveReferences.isEmpty(),
        "failed JNI allocation must leave no published Surface or reference");
    check(output.surfaceTextureEntry.surfaces.size() == 2 &&
        output.surfaceTextureEntry.surfaces.stream().allMatch(s -> s.released),
        "failed JNI allocation must immediately release the newly allocated Surface");
    output.newGlobalObjectRef.fail = false;
    output.newGlobalObjectRef.returnZero = false;
    long recovered = output.createSurface(new OutputOperationToken());
    check(recovered != 0 && output.liveReferences.get(recovered) == output.surface &&
        !output.surface.released, "creation can recover after failed JNI allocation");
    disposeAndCheck(output, "JNI allocation recovery");
  }

  static void rollbackReleaseFailure() {
    SurfaceCreationProbe output = new SurfaceCreationProbe();
    output.newGlobalObjectRef.fail = true;
    output.surfaceTextureEntry.failNewSurfaceRelease = true;
    RuntimeException failure = expectRuntimeException(
        () -> output.createSurface(new OutputOperationToken()),
        "failed JNI allocation and rollback must escape createSurface");
    check(output.wid == 0 && output.liveReferences.isEmpty() &&
        output.surface != null && !output.surface.released,
        "failed rollback must retain ownership of the unreleased Surface");
    check(failure.getCause() != null && failure.getCause().getSuppressed().length == 1,
        "creation failure must retain the rollback error");
    output.surface.failRelease = false;
    disposeAndCheck(output, "rollback release recovery");
  }

  public static void main(String[] args) {
    normalReplacementAndDisposal();
    surfaceReleaseFailure();
    jniDeleteFailure();
    simultaneousDeleteAndCreationFailure();
    surfaceConstructionFailure();
    newReferenceFailure(false);
    newReferenceFailure(true);
    rollbackReleaseFailure();
    System.out.println("PASS: Surface replacement, cleanup failures, creation rollback and recovery");
  }
}
"""


def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        type=Path,
        default=root / "third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video/VideoOutput.java",
        help="VideoOutput.java to probe (defaults to the production source)",
    )
    args = parser.parse_args()

    source = args.source.read_text(encoding="utf-8")
    output = root / "build/probe-validation/android-surface-creation"
    output.mkdir(parents=True, exist_ok=True)
    java = output / "SurfaceCreationProbe.java"
    harness = HARNESS.replace(
        "__CREATE_SURFACE_METHOD__", method(source, "public long createSurface(")
    )
    harness = harness.replace(
        "__DISPOSE_METHOD__", method(source, "public void dispose(")
    )
    harness = harness.replace(
        "__COMPLETE_DISPOSE_METHOD__", method(source, "private void completeDispose(")
    )
    java.write_text(harness, encoding="utf-8")

    compiled = subprocess.run(
        ["javac", "-d", str(output), str(java)], capture_output=True, text=True
    )
    if compiled.returncode:
        if compiled.stdout:
            print(compiled.stdout, end="", file=sys.stderr)
        if compiled.stderr:
            print(compiled.stderr, end="", file=sys.stderr)
        return compiled.returncode

    result = subprocess.run(
        ["java", "-cp", str(output), "SurfaceCreationProbe"],
        capture_output=True,
        text=True,
    )
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())

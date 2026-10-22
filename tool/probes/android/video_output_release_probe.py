"""Run the production Java disposal methods with host-only resource doubles."""
from pathlib import Path
import argparse
import subprocess


def method(source, signature):
    start = source.index(signature)
    body = source.index("{", start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


HARNESS = r"""
import java.util.*;
public class VideoOutputReleaseProbe {
  final Object lock = new Object();
  boolean disposeComplete, disposed;
  String disposeError;
  long surfaceGeneration, wid = 123;
  final List<MethodChannel.Result> disposeResults = new ArrayList<>();
  final List<String> events = new ArrayList<>();
  final Resource surfaceTextureEntry = new Resource("texture");
  Resource surface = new Resource("surface");
  final Gate operationGate = new Gate();
  final Handler mainHandler = new Handler();
  final DeleteReference deleteGlobalObjectRef = new DeleteReference();
  class Resource {
    final String label;
    Resource(String label) { this.label = label; }
    void release() { events.add(label); }
  }
  static class Gate { void revoke() {} }
  static class Handler {
    boolean postDelayed(Runnable action, long delay) { return true; }
  }
  class DeleteReference {
    boolean fail;
    void invoke(Object unused, long value) {
      events.add("jni");
      if (fail) throw new IllegalStateException("JNI release failed");
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
  void transitionSampling(String admission) { events.add("sampling." + admission); }
  void resetFrameSamples() {}
  void finishFrameWait(boolean accepted) {}
  void diagnostic(String event, Throwable error) {}
  DISPOSE
  COMPLETE
  static void check(boolean value, String message) {
    if (!value) throw new AssertionError(message);
  }
  public static void main(String[] args) {
    var output = new VideoOutputReleaseProbe();
    var first = new MethodChannel.Result();
    output.dispose(first);
    check(first.successes == 1, "release receipt must follow JNI deletion without a fixed delay");
    check(output.wid == 0, "released JNI reference must be cleared");
    check(output.events.equals(List.of("sampling.blocked", "texture", "surface", "jni")), "resource release order");
    var repeated = new MethodChannel.Result();
    output.dispose(repeated);
    check(repeated.successes == 1 && output.events.size() == 4, "idempotent release receipt");
    var broken = new VideoOutputReleaseProbe();
    broken.deleteGlobalObjectRef.fail = true;
    var error = new MethodChannel.Result();
    broken.dispose(error);
    check(error.errors == 1 && error.successes == 0, "JNI failure cannot acknowledge release");
    var errorAgain = new MethodChannel.Result();
    broken.dispose(errorAgain);
    check(errorAgain.errors == 1 && broken.events.size() == 4, "failed reference stays quarantined");
    var empty = new VideoOutputReleaseProbe();
    empty.wid = 0;
    var noReference = new MethodChannel.Result();
    empty.dispose(noReference);
    check(noReference.successes == 1 && empty.events.size() == 3, "output without JNI reference");
    System.out.println("PASS: production Surface disposal, immediate receipt, idempotence and JNI failure");
  }
}
"""


def main():
    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=root / "third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video/VideoOutput.java")
    args = parser.parse_args()
    source = args.source.read_text(encoding="utf-8")
    output = root / "build/probe-validation/android-release"
    output.mkdir(parents=True, exist_ok=True)
    java = output / "VideoOutputReleaseProbe.java"
    java.write_text(HARNESS.replace("DISPOSE", method(source, "public void dispose(")).replace("COMPLETE", method(source, "private void completeDispose(")), encoding="utf-8")
    subprocess.run(["javac", "-d", str(output), str(java)], check=True)
    subprocess.run(["java", "-cp", str(output), "VideoOutputReleaseProbe"], check=True)


if __name__ == "__main__":
    main()

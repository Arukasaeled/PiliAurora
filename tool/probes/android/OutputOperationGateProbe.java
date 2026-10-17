package com.alexmercerind.media_kit_video;

/** Host-JVM regression for Android output-token revocation and ordering. */
public final class OutputOperationGateProbe {
    public static void main(String[] args) {
        final OutputOperationGate gate = new OutputOperationGate();
        final OutputOperationToken first = token(4, 2, 8, 1);
        check(gate.begin(first), "first output generation begins");
        check(gate.isCurrent(first), "active generation permits frame wait");
        check(gate.invalidate(first), "active generation revokes");
        check(!gate.isCurrent(first), "late frame wait is rejected after revocation");
        check(!gate.begin(first), "late begin cannot resurrect a revoked generation");
        check(!gate.begin(token(4, 1, 99, 99)), "lower load cannot replace high-water mark");
        check(!gate.invalidate(first), "duplicate revoke is not accepted as current");

        final OutputOperationToken next = token(4, 3, 1, 0);
        check(gate.begin(next), "later load replaces revoked generation");
        check(gate.isCurrent(next), "later generation is active");
        check(!gate.isCurrent(first), "old generation remains rejected");

        final OutputOperationToken newRuntime = token(5, 1, 1, 0);
        check(gate.begin(newRuntime), "higher runtime replaces prior runtime");
        check(!gate.begin(next), "late previous-runtime begin is rejected");
        check(!gate.isCurrent(next), "previous-runtime wait is rejected");
        System.out.println("PASS: Android output generation gate revocation and high-water ordering");
    }

    private static OutputOperationToken token(long runtime, long load, long epoch, long revision) {
        return new OutputOperationToken(runtime, load, epoch, revision);
    }

    private static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
    }
}

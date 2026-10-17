package com.alexmercerind.media_kit_video;

import java.util.Map;
import java.util.Objects;

/** Immutable identity checked inside the Surface mutation critical section. */
final class OutputOperationToken {
    final long runtimeId;
    final long loadId;
    final long outputEpoch;
    final long configRevision;

    OutputOperationToken(long runtimeId, long loadId, long outputEpoch, long configRevision) {
        this.runtimeId = runtimeId;
        this.loadId = loadId;
        this.outputEpoch = outputEpoch;
        this.configRevision = configRevision;
    }

    static OutputOperationToken from(Map<?, ?> values) {
        return new OutputOperationToken(
                Long.parseLong(Objects.requireNonNull(String.valueOf(values.get("runtimeId")))),
                Long.parseLong(Objects.requireNonNull(String.valueOf(values.get("loadId")))),
                Long.parseLong(Objects.requireNonNull(String.valueOf(values.get("outputEpoch")))),
                Long.parseLong(Objects.requireNonNull(String.valueOf(values.get("configRevision"))))
        );
    }

    boolean sameAs(OutputOperationToken other) {
        return other != null
                && runtimeId == other.runtimeId
                && loadId == other.loadId
                && outputEpoch == other.outputEpoch
                && configRevision == other.configRevision;
    }

    boolean canReplace(OutputOperationToken current) {
        if (current == null) return true;
        if (runtimeId != current.runtimeId) return runtimeId > current.runtimeId;
        if (loadId != current.loadId) return loadId > current.loadId;
        if (outputEpoch != current.outputEpoch) return outputEpoch > current.outputEpoch;
        return configRevision > current.configRevision;
    }
}

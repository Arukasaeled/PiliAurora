package com.alexmercerind.media_kit_video;

/**
 * Tracks the active output generation and its permanent high-water mark.
 * Callers serialize access with the output's lifecycle lock.
 */
final class OutputOperationGate {
    private OutputOperationToken highWaterToken;
    private OutputOperationToken activeToken;
    private boolean activeTokenValid;

    boolean begin(OutputOperationToken token) {
        if (activeToken != null && activeToken.sameAs(token)) return activeTokenValid;
        if (highWaterToken != null && !token.canReplace(highWaterToken)) return false;
        highWaterToken = token;
        activeToken = token;
        activeTokenValid = true;
        return true;
    }

    boolean invalidate(OutputOperationToken token) {
        if (!isCurrent(token)) return false;
        activeTokenValid = false;
        return true;
    }

    boolean isCurrent(OutputOperationToken token) {
        return activeTokenValid && activeToken != null && activeToken.sameAs(token);
    }

    OutputOperationToken activeToken() {
        return activeToken;
    }

    void revoke() {
        activeTokenValid = false;
    }
}

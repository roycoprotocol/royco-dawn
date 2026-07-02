import "./summaries-AccountantDefs.spec";

// Ghost variable that tracks the last timestamp.
ghost mathint lastTimestamp;

// The maximum timestamp the protocol supports
definition MAX_TIMESTAMP() returns mathint = max_uint32 - 86400 * 365;

hook TIMESTAMP uint256 time {
    require to_mathint(time) < MAX_TIMESTAMP(), "timestamp below protocol end date";
    require to_mathint(time) >= lastTimestamp, "timestamp is monotone";
    lastTimestamp = time;
}

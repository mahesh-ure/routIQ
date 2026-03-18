/**
 * URE_GovLimits
 * ─────────────────────────────────────────────────────────────────────────────
 * Point-in-time snapshot of all Apex governor limits for the current transaction.
 * Lightweight utility — Limits.* calls are free (no SOQL, no CPU overhead).
 *
 * Used by URE_Logger to:
 *   - Attach a compact limit summary to log entries
 *   - Emit automatic WARN entries when limits approach threshold
 *   - Populate the URE_Log__c header fields at flush time
 *
 * Design constraints
 *   - No SOQL. No DML. No heap allocations beyond this one object.
 *   - All fields are read-only after construction (private setters).
 *   - JSON serialisation only happens when explicitly requested (toJson()).
 *
 * Namespace: ure
 * API Version: 65.0
 * Author: routIQ Engineering — CTA-reviewed
 * ─────────────────────────────────────────────────────────────────────────────
 */
public without sharing class URE_GovLimits {

    // ─── Raw Limits ───────────────────────────────────────────────────────────

    /** SOQL queries consumed in this transaction. */
    public Integer soqlUsed      { get; private set; }
    /** SOQL query limit for this transaction context (100 sync / 200 async). */
    public Integer soqlLimit     { get; private set; }

    /** DML statements consumed. */
    public Integer dmlStmtsUsed  { get; private set; }
    /** DML statement limit (150 sync). */
    public Integer dmlStmtsLimit { get; private set; }

    /** DML rows processed. */
    public Integer dmlRowsUsed   { get; private set; }
    /** DML row limit (10,000 sync). */
    public Integer dmlRowsLimit  { get; private set; }

    /** CPU milliseconds consumed. */
    public Long    cpuUsedMs     { get; private set; }
    /** CPU limit in milliseconds (10,000 sync). */
    public Long    cpuLimitMs    { get; private set; }

    /** Heap consumed in bytes. */
    public Long    heapUsedBytes { get; private set; }
    /** Heap limit in bytes (6,000,000 sync). */
    public Long    heapLimitBytes{ get; private set; }

    /** Query rows returned across all SOQL. */
    public Integer queryRowsUsed { get; private set; }
    /** Query row limit (50,000 sync). */
    public Integer queryRowsLimit{ get; private set; }

    /** Callouts consumed. */
    public Integer calloutsUsed  { get; private set; }
    /** Callout limit (100 sync). */
    public Integer calloutLimit  { get; private set; }

    // ─── Derived Percentages ──────────────────────────────────────────────────

    /** Percentage of SOQL queries consumed. */
    public Decimal soqlPct       { get; private set; }
    /** Percentage of CPU time consumed. */
    public Decimal cpuPct        { get; private set; }
    /** Percentage of heap consumed. */
    public Decimal heapPct       { get; private set; }
    /** Percentage of DML rows consumed. */
    public Decimal dmlRowsPct    { get; private set; }
    /** Percentage of query rows consumed. */
    public Decimal queryRowsPct  { get; private set; }

    /** ISO-format string of when this snapshot was taken. */
    public String  capturedAt    { get; private set; }

    // ─── Private constructor — use capture() ─────────────────────────────────
    private URE_GovLimits() {}

    // ─── Factory ─────────────────────────────────────────────────────────────

    /**
     * Capture a complete governor limit snapshot at the current point in time.
     *
     * All Limits.* calls are governor-free.
     * No SOQL, no DML, no CPU budget consumed beyond native method calls.
     *
     * @return  URE_GovLimits  Immutable snapshot.
     */
    public static URE_GovLimits capture() {
        URE_GovLimits s   = new URE_GovLimits();

        s.soqlUsed        = Limits.getQueries();
        s.soqlLimit       = Limits.getLimitQueries();

        s.dmlStmtsUsed    = Limits.getDmlStatements();
        s.dmlStmtsLimit   = Limits.getLimitDmlStatements();

        s.dmlRowsUsed     = Limits.getDmlRows();
        s.dmlRowsLimit    = Limits.getLimitDmlRows();

        s.cpuUsedMs       = Limits.getCpuTime();
        s.cpuLimitMs      = Limits.getLimitCpuTime();

        s.heapUsedBytes   = Limits.getHeapSize();
        s.heapLimitBytes  = Limits.getLimitHeapSize();

        s.queryRowsUsed   = Limits.getQueryRows();
        s.queryRowsLimit  = Limits.getLimitQueryRows();

        s.calloutsUsed    = Limits.getCallouts();
        s.calloutLimit    = Limits.getLimitCallouts();

        s.capturedAt      = String.valueOf(System.now());

        // Derived percentages — rounded to 1 d.p.
        s.soqlPct         = pct(s.soqlUsed,      s.soqlLimit);
        s.cpuPct          = pct(s.cpuUsedMs,      s.cpuLimitMs);
        s.heapPct         = pct(s.heapUsedBytes,  s.heapLimitBytes);
        s.dmlRowsPct      = pct(s.dmlRowsUsed,    s.dmlRowsLimit);
        s.queryRowsPct    = pct(s.queryRowsUsed,  s.queryRowsLimit);

        return s;
    }

    // ─── Display Helpers ─────────────────────────────────────────────────────

    /**
     * Compact one-liner suitable for log message bodies.
     * Example:
     *   SOQL 4/100 (4.0%) | DML 1/150 | CPU 312/10000ms (3.1%) |
     *   Heap 128/5859KB (2.2%) | QRows 47/50000
     */
    public String toCompactDisplay() {
        return 'SOQL '        + soqlUsed      + '/' + soqlLimit     + ' ('  + soqlPct     + '%) | '
             + 'DML '         + dmlStmtsUsed  + '/' + dmlStmtsLimit + ' | '
             + 'CPU '         + cpuUsedMs     + '/' + cpuLimitMs    + 'ms (' + cpuPct    + '%) | '
             + 'Heap '        + kb(heapUsedBytes) + '/' + kb(heapLimitBytes) + 'KB (' + heapPct + '%) | '
             + 'QRows '       + queryRowsUsed + '/' + queryRowsLimit;
    }

    /**
     * Returns true if any single limit is at or above the given threshold (0–100).
     * Used by URE_Logger to auto-emit WARN entries before they become failures.
     *
     * @param  thresholdPct  e.g. 70 = warn at 70% consumed.
     * @return Boolean
     */
    public Boolean isApproachingLimit(Decimal thresholdPct) {
        return soqlPct      >= thresholdPct
            || cpuPct       >= thresholdPct
            || heapPct      >= thresholdPct
            || dmlRowsPct   >= thresholdPct
            || queryRowsPct >= thresholdPct;
    }

    /**
     * Returns the highest percentage consumed across all tracked limits.
     * Used to sort or rank urgency.
     */
    public Decimal highWaterMark() {
        Decimal max = 0;
        for (Decimal d : new List<Decimal>{ soqlPct, cpuPct, heapPct, dmlRowsPct, queryRowsPct }) {
            if (d > max) max = d;
        }
        return max;
    }

    /**
     * Full JSON representation — only call at flush time to avoid CPU waste.
     * Returns a serialised map, not this object, to control field visibility.
     */
    public String toJson() {
        Map<String, Object> m = new Map<String, Object>{
            'capturedAt'    => capturedAt,
            'soql'          => new Map<String,Object>{ 'used'=>soqlUsed,     'limit'=>soqlLimit,      'pct'=>soqlPct      },
            'dmlStatements' => new Map<String,Object>{ 'used'=>dmlStmtsUsed, 'limit'=>dmlStmtsLimit                       },
            'dmlRows'       => new Map<String,Object>{ 'used'=>dmlRowsUsed,  'limit'=>dmlRowsLimit,   'pct'=>dmlRowsPct   },
            'cpu'           => new Map<String,Object>{ 'usedMs'=>cpuUsedMs,  'limitMs'=>cpuLimitMs,   'pct'=>cpuPct       },
            'heap'          => new Map<String,Object>{ 'usedBytes'=>heapUsedBytes,'limitBytes'=>heapLimitBytes,'pct'=>heapPct },
            'queryRows'     => new Map<String,Object>{ 'used'=>queryRowsUsed,'limit'=>queryRowsLimit,  'pct'=>queryRowsPct },
            'callouts'      => new Map<String,Object>{ 'used'=>calloutsUsed, 'limit'=>calloutLimit                        }
        };
        return JSON.serialize(m);
    }

    // ─── Private Helpers ─────────────────────────────────────────────────────

    private static Decimal pct(Long used, Long limit) {
        if (limit == null || limit == 0) return 0;
        return (used * 100.0 / limit).setScale(1, RoundingMode.HALF_UP);
    }

    private static Decimal pct(Integer used, Integer limit) {
        return pct(Long.valueOf(used == null ? 0 : used),
                   Long.valueOf(limit == null ? 0 : limit));
    }

    /** Convert bytes → KB, rounded. */
    private static Long kb(Long bytes) {
        return bytes == null ? 0 : (bytes / 1024);
    }
}

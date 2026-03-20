/**
 * @description Custom exception thrown when no agent matches ALL mandatory capability
 *              conditions for a routing config. Provides structured details about which
 *              capabilities failed so the admin can correct agent setup.
 *
 *              v2 design decision: instead of silently returning no-match or falling back
 *              to a queue, this exception surfaces actionable information to the requesting
 *              agent and the audit log. The admin sees exactly which capability values are
 *              missing across the agent pool.
 *
 *              Never thrown for optional (non-mandatory) capability mismatches.
 *
 * @group Worker
 */
public with sharing class CapabilityMismatchException extends Exception {

    /** Capability label → required value that no agent could satisfy. */
    private Map<String, String> missingCapabilities;

    /** Config DeveloperName that triggered the mismatch. */
    private String configDeveloperName;

    // ─── Factory ────────────────────────────────────────────────────────────

    /**
     * @description Creates a CapabilityMismatchException with structured details.
     *
     * @param configDevName   The routing config that was being evaluated
     * @param missingCaps     Map of capability label → required value (from work record)
     * @return Fully populated exception ready to throw
     */
    public static CapabilityMismatchException create(
        String configDevName,
        Map<String, String> missingCaps
    ) {
        List<String> details = new List<String>();
        for (String capLabel : missingCaps.keySet()) {
            details.add(capLabel + ' = ' + missingCaps.get(capLabel));
        }

        String message = 'No agents match mandatory capabilities for config "'
            + configDevName + '". Missing agent setup values: '
            + String.join(details, '; ')
            + '. Please contact your administrator to update agent capability assignments.';

        CapabilityMismatchException ex = new CapabilityMismatchException(message);
        ex.missingCapabilities = missingCaps;
        ex.configDeveloperName = configDevName;
        return ex;
    }

    // ─── Accessors ──────────────────────────────────────────────────────────

    /**
     * @description Returns the map of capability labels to the required values
     *              that no agent could satisfy. Used by AuditLogger for structured logging.
     */
    public Map<String, String> getMissingCapabilities() {
        return this.missingCapabilities != null
            ? this.missingCapabilities
            : new Map<String, String>();
    }

    /**
     * @description Returns the config DeveloperName that triggered this exception.
     */
    public String getConfigDeveloperName() {
        return this.configDeveloperName;
    }
}

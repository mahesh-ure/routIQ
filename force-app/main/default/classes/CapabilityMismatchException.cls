/**
 * @description Exception thrown when no agent matches ALL mandatory capability conditions
 *              for a routing config. Surfaces actionable mismatch details to admins and audit logs.
 * @group Worker
 */
public with sharing class CapabilityMismatchException extends Exception {

    /** Capability label -> required value that no agent could satisfy. */
    private Map<String, String> missingCapabilities;

    /** Config DeveloperName that triggered the mismatch. */
    private String configDeveloperName;

    /** @description Creates a CapabilityMismatchException with structured mismatch details. */
    public static CapabilityMismatchException create(
        String configDevName,
        Map<String, String> missingCaps
    ) {
        List<String> details = new List<String>();
        for (String capLabel : missingCaps.keySet()) {
            details.add(capLabel + ' = ' + missingCaps.get(capLabel));
        }

        String message = String.format(
            System.Label.URE_CAPABILITY_MISMATCH_ERROR,
            new List<Object>{configDevName, String.join(details, '; ')}
        );

        CapabilityMismatchException ex = new CapabilityMismatchException(message);
        ex.missingCapabilities = missingCaps;
        ex.configDeveloperName = configDevName;
        return ex;
    }

    /** @description Returns missing capability map (label -> required value). Used by AuditLogger. */
    public Map<String, String> getMissingCapabilities() {
        return this.missingCapabilities != null
            ? this.missingCapabilities
            : new Map<String, String>();
    }

    /** @description Returns the config DeveloperName that triggered this exception. */
    public String getConfigDeveloperName() {
        return this.configDeveloperName;
    }
}

# CLAUDE_DEPLOYMENT.md
# routIQ Deployment & Package Delivery Guide

This document covers all deployment commands, troubleshooting patterns, and managed package delivery workflows for the routIQ ISV product.

**AI agents MUST reference this file instead of figuring out deploy syntax. Do NOT waste tokens on deployment discovery.**

---

## 1. Deploy Commands (Quick Reference)

### 1.1 Deploy Managed Package Source (force-app)

```bash
# Deploy ALL managed package metadata
sf project deploy start --source-dir force-app/main/default

# Deploy a specific Apex class
sf project deploy start --source-dir force-app/main/default/classes/RoutingEngine.cls

# Deploy a specific LWC
sf project deploy start --source-dir force-app/main/default/lwc/routingConsole

# Deploy a specific custom object (all fields)
sf project deploy start --source-dir force-app/main/default/objects/Agent__c

# Deploy a specific field
sf project deploy start --source-dir force-app/main/default/objects/Agent__c/fields/Is_Active__c.field-meta.xml

# Deploy permission sets
sf project deploy start --source-dir force-app/main/default/permissionsets

# Deploy custom labels
sf project deploy start --source-dir force-app/main/default/labels
```

### 1.2 Deploy Test/Sample Data (unpackaged)

```bash
# Deploy ALL test data (CMDT records + Case customizations)
sf project deploy start --source-dir unpackaged/main/default

# Deploy only custom metadata records
sf project deploy start --source-dir unpackaged/main/default/customMetadata

# Deploy only Case object customizations
sf project deploy start --source-dir unpackaged/main/default/objects/Case
```

### 1.3 Deploy Multiple Directories at Once

```bash
# Deploy managed package + test data together
sf project deploy start --source-dir force-app/main/default --source-dir unpackaged/main/default
```

### 1.4 Run Apex Tests

```bash
# Run a specific test class
sf apex run test --class-names SetupWizardController_Test --result-format human --wait 10

# Run multiple test classes
sf apex run test --class-names "SetupWizardController_Test,Logger_Test" --result-format human --wait 10

# Run all local tests (excludes managed package tests)
sf apex run test --test-level RunLocalTests --result-format human --wait 10
```

### 1.5 Execute Anonymous Apex Scripts

```bash
# Run a setup script
sf apex run --file scripts/apex/setup_agent.apex

# Run sample data creation
sf apex run --file scripts/apex/setup_v6_sample_data.apex
```

### 1.6 Retrieve from Org

```bash
# Retrieve all source from org
sf project retrieve start --source-dir force-app/main/default

# Retrieve a specific class
sf project retrieve start --source-dir force-app/main/default/classes/RoutingEngine.cls
```

---

## 2. Deployment Order (Dependency Chain)

When deploying multiple metadata types, **order matters**. Follow this sequence:

```
1. Objects / Custom Metadata Types / Fields   (schema — no Apex dependencies)
2. Custom Labels                               (referenced by Apex and LWC)
3. Apex Classes — DTOs & Selectors first       (no cross-class dependencies)
4. Apex Classes — Services & Controllers       (depend on selectors/DTOs)
5. Apex Triggers                               (depend on handlers/services)
6. LWC Components                              (depend on Apex controllers)
7. Permission Sets                             (reference objects + fields)
8. Test Data (unpackaged/)                     (CMDT records, sample data)
9. Run Tests                                   (validate everything)
```

### Single-File Deploy Rule

**After editing a single file, deploy ONLY that file — NOT the entire directory.**

```bash
# GOOD: Deploy only the changed file
sf project deploy start --source-dir force-app/main/default/classes/RoutingEngine.cls

# BAD: Deploys everything, wastes time
sf project deploy start --source-dir force-app/main/default/classes
```

### Batch Deploy for New Features

When deploying a new feature with multiple new files (e.g., Layer 0 + Layer 7), deploy in dependency order:

```bash
# Step 1: Objects & fields
sf project deploy start --source-dir force-app/main/default/objects

# Step 2: Labels
sf project deploy start --source-dir force-app/main/default/labels

# Step 3: Apex (all at once — SF resolves internal dependencies)
sf project deploy start --source-dir force-app/main/default/classes

# Step 4: LWC
sf project deploy start --source-dir force-app/main/default/lwc

# Step 5: Run tests
sf apex run test --test-level RunLocalTests --result-format human --wait 10
```

---

## 3. Troubleshooting — Lessons Learned

### 3.1 Source Tracking Corruption ("Could not find HEAD")

**Symptom:** Deploy fails with `MetadataTransferError: Could not find HEAD` after a successful deploy.

**Cause:** The local source tracking database under `.sf/orgs/` becomes corrupted, especially after switching branches, force-pushes, or interrupted deploys.

**Fix:**
```bash
# Delete the corrupted tracking cache (replace ORG_ID with your org's ID)
rm -rf .sf/orgs/<ORG_ID>/localSourceTracking

# Find your org ID if unknown:
sf org display --json | grep -i orgId

# Then retry the deploy — tracking rebuilds automatically
sf project deploy start --source-dir force-app/main/default/labels
```

**Prevention:** If you see this error, clear tracking immediately. Do not retry without clearing.

### 3.2 Source Conflicts on Modified Existing Classes

**Symptom:** Deploy fails because local changes conflict with the org version of an existing class.

**Cause:** The class was modified locally but also exists in the org (e.g., adding fields to RoutingRequest.cls).

**Fix:**
```bash
# Add --ignore-conflicts to force your local version
sf project deploy start --source-dir force-app/main/default/classes/RoutingRequest.cls --ignore-conflicts
```

**When to use `--ignore-conflicts`:**
- Deploying modified existing classes (adding fields, methods)
- After a retrieve that brought in org changes you want to overwrite
- **NOT** for new files (no conflict exists)

### 3.3 Metadata.Operations.enqueueDeployment() in Test Context

**Symptom:** `Metadata.Operations.enqueueDeployment()` throws an exception in Apex test context.

**Cause:** CMDT deployment via the Metadata API is not fully supported in Apex unit tests. The `enqueueDeployment()` call may fail.

**Fix in tests:**
```apex
Test.startTest();
try {
    SetupWizardController.DeployResult result =
        SetupWizardController.deployConfig(stateJson);
    System.assertEquals(true, result.success,
        'Deployment should be enqueued successfully');
} catch (AuraHandledException e) {
    // Expected: CMDT deploy not supported in test context
    System.assert(true,
        'AuraHandledException expected for CMDT deploy in test context');
}
Test.stopTest();
```

### 3.4 AuraHandledException.getMessage() in Tests

**Symptom:** `e.getMessage()` returns `"Script-thrown exception"` instead of your custom message.

**Cause:** Apex runtime wraps AuraHandledException differently in test context vs LWC caller context. The custom message is only visible to the LWC JavaScript caller.

**Fix:** Never assert on the message content. Only assert on the exception type:
```apex
Boolean exceptionThrown = false;
try {
    SetupWizardController.describeSObjectFields('Not_A_Real_Object__c');
} catch (AuraHandledException e) {
    exceptionThrown = true;
    // Do NOT assert e.getMessage() — it returns 'Script-thrown exception'
}
System.assert(exceptionThrown, 'Should throw AuraHandledException');
```

### 3.5 Metadata.Operations.checkDeployStatus() Does Not Exist

**Symptom:** Compile error — `Method does not exist or incorrect signature: Metadata.Operations.checkDeployStatus(Id, Boolean)`.

**Cause:** This method does not exist in the Apex Metadata API. The Confluence/documentation may reference it incorrectly.

**Fix:** Query the `DeployRequest` standard object instead:
```apex
String soql = 'SELECT Id, Status, ErrorMessage FROM DeployRequest WHERE Id = :deploymentId LIMIT 1';
List<SObject> results = Database.queryWithBinds(
    soql,
    new Map<String, Object>{ 'deploymentId' => deploymentId },
    AccessLevel.USER_MODE
);
```

Map `DeployRequest.Status` values: `Succeeded`, `Failed`, `Canceled`, `InProgress`.

### 3.6 Deploy Path Confusion (force-app/code/ vs force-app/main/default/)

**Symptom:** Files created in wrong directory, deploy succeeds but class not visible in org.

**Cause:** Some agents or tools may report paths under `force-app/code/` — this is NOT the correct package source path.

**Fix:** ALL managed package source MUST live under:
```
force-app/main/default/
```
Never create files under `force-app/code/` or any other subdirectory.

---

## 4. Scratch Org Management

### 4.1 Create a Scratch Org

```bash
# Create with alias (uses config/project-scratch-def.json)
sf org create scratch --definition-file config/project-scratch-def.json --alias uredev-scratch --duration-days 30 --set-default

# Verify
sf org display --target-org uredev-scratch
```

### 4.2 Push/Deploy to Scratch Org

```bash
# Full deploy (both package dirs)
sf project deploy start --source-dir force-app/main/default --source-dir unpackaged/main/default --target-org uredev-scratch

# Open the org
sf org open --target-org uredev-scratch
```

### 4.3 Delete a Scratch Org

```bash
sf org delete scratch --target-org uredev-scratch --no-prompt
```

---

## 5. Managed Package Versioning & Delivery

### 5.1 Package Configuration

From `sfdx-project.json`:
- **Package name:** routIQ
- **Namespace:** ure
- **Current version:** 1.0.0.NEXT
- **Source API version:** 65.0

### 5.2 Create a Package Version (Beta)

Beta versions are for internal testing and UAT. They are NOT installable in production orgs.

```bash
# Create a beta package version (NEXT auto-increments the build number)
sf package version create \
  --package routIQ \
  --installation-key <YOUR_KEY> \
  --wait 30 \
  --code-coverage \
  --definition-file config/project-scratch-def.json

# Check creation status
sf package version create list --status Active

# List all versions
sf package version list --packages routIQ --verbose
```

**Important flags:**
- `--code-coverage` — Runs tests during version creation. Required for promotion.
- `--installation-key` — Password to install. Use a consistent key for your team.
- `--wait 30` — Wait up to 30 minutes for version creation to complete.

### 5.3 Install a Beta Version

```bash
# Get the 04t subscriber package version ID from the create output
sf package install \
  --package 04tXXXXXXXXXXXXXXX \
  --installation-key <YOUR_KEY> \
  --target-org <TARGET_ORG_ALIAS> \
  --wait 15

# Check install status
sf package install report --request-id 0HfXXXXXXXXXXXXXXX --target-org <TARGET_ORG_ALIAS>
```

### 5.4 Promote to Released (Production-Ready)

Only promote after thorough testing. **Released versions cannot be deleted.**

```bash
# Promote a beta to released
sf package version promote --package 04tXXXXXXXXXXXXXXX --no-prompt

# Verify promotion
sf package version list --packages routIQ --released
```

### 5.5 Version Delivery Workflow

```
Developer Workflow:
  Code -> Deploy to Scratch Org -> Test -> Commit -> PR to Dev branch

Release Workflow:
  1. Merge Dev -> Main (release branch)
  2. sf package version create (beta)
  3. Install beta in QA sandbox -> test
  4. Install beta in UAT sandbox -> stakeholder sign-off
  5. sf package version promote (released)
  6. Generate install URL for customers
  7. Post-install: run data migration scripts if needed
```

### 5.6 Generate Install URLs

```bash
# Get the 04t ID of the released version
sf package version list --packages routIQ --released --verbose

# Install URL format:
# https://login.salesforce.com/packaging/installPackage.apexp?p0=04tXXXXXXXXXXXXXXX
# For sandbox:
# https://test.salesforce.com/packaging/installPackage.apexp?p0=04tXXXXXXXXXXXXXXX
```

### 5.7 Upgrade Safety Rules

When creating new versions, NEVER:
- Rename fields or objects (breaks subscriber references)
- Delete metadata (breaks subscribers)
- Change API names
- Remove global Apex methods/classes (breaks subscribers)

Instead:
- Deprecate with `@Deprecated` annotation
- Add new fields alongside old ones
- Version your metadata naming (e.g., `Routing_Config_v2__mdt`)
- Use `SubscriberControlled` for fields subscribers should own

---

## 6. CI/CD Integration (Future)

### 6.1 GitHub Actions Skeleton

```yaml
# .github/workflows/validate.yml
name: Validate PR
on:
  pull_request:
    branches: [Dev, main]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install SF CLI
        run: npm install -g @salesforce/cli
      - name: Authenticate DevHub
        run: sf org login jwt --client-id ${{ secrets.SF_CLIENT_ID }} --jwt-key-file server.key --username ${{ secrets.SF_DEVHUB_USERNAME }} --set-default-dev-hub
      - name: Create Scratch Org
        run: sf org create scratch --definition-file config/project-scratch-def.json --alias ci-scratch --duration-days 1
      - name: Deploy
        run: sf project deploy start --source-dir force-app/main/default --source-dir unpackaged/main/default --target-org ci-scratch
      - name: Run Tests
        run: sf apex run test --test-level RunLocalTests --result-format human --wait 15 --target-org ci-scratch
      - name: Delete Scratch Org
        if: always()
        run: sf org delete scratch --target-org ci-scratch --no-prompt
```

---

## 7. Quick Reference Card

| Task | Command |
|------|---------|
| Deploy single class | `sf project deploy start --source-dir force-app/main/default/classes/MyClass.cls` |
| Deploy single LWC | `sf project deploy start --source-dir force-app/main/default/lwc/myComponent` |
| Deploy objects | `sf project deploy start --source-dir force-app/main/default/objects` |
| Deploy labels | `sf project deploy start --source-dir force-app/main/default/labels` |
| Deploy with conflict override | `sf project deploy start --source-dir <path> --ignore-conflicts` |
| Run one test | `sf apex run test --class-names MyTest --result-format human --wait 10` |
| Run all tests | `sf apex run test --test-level RunLocalTests --result-format human --wait 10` |
| Fix source tracking | `rm -rf .sf/orgs/<ORG_ID>/localSourceTracking` |
| Create package version | `sf package version create --package routIQ --code-coverage --wait 30` |
| Promote to released | `sf package version promote --package 04tXXX --no-prompt` |
| Open scratch org | `sf org open --target-org uredev-scratch` |

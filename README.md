# Collect Import semantic model sizes for Fabric capacity planning

Use this guide to measure **Import-only** Power BI semantic models in a selected list of workspaces. The results help narrow down which Microsoft Fabric SKUs to test. They do not determine a SKU on their own.

| Choose | When to use it |
|---|---|
| [**PowerShell**](#option-1-powershell) | A Fabric administrator can run the export on Windows and wants a local CSV. No Fabric notebook or Lakehouse is needed. |
| [**Fabric Python notebook**](#option-2-fabric-python-notebook) | You can run a notebook in Fabric and want to select workspaces by name or ID, then view results in the notebook or save them to a Lakehouse. The notebook lists only workspaces and models visible to the running account. |

## Before you start

1. List the regular workspaces you intend to move. Use workspace IDs where possible: the GUID appears after `/groups/` in the workspace URL. Do not include **My Workspace**, **Admin monitoring**, or other admin/system workspaces. Start with one workspace that contains a known Import model.
2. Verify that each **source** workspace has a [supported XMLA endpoint](https://learn.microsoft.com/en-us/fabric/enterprise/powerbi/service-premium-connect-tools) and that tenant and capacity settings allow your account to use it. **Read Only** is sufficient; you do not need to enable XMLA Read Write. A model on ordinary shared capacity may appear in an inventory but cannot be sized through this XMLA workflow.
3. Use an account with XMLA access and [Write permission on each target semantic model](https://learn.microsoft.com/en-us/dax/info-storagetablecolumnsegments-function-dax) to read the storage statistics. Build alone is not enough for this query. Being a Fabric administrator lets you use the admin inventory APIs but does not automatically give you access to query every model.

The sizing queries do not modify or refresh the source models, but XMLA connections can cause models to load. Run large collections off-peak.

## Option 1: PowerShell

**Prerequisites:** PowerShell 7 on Windows, the `MicrosoftPowerBIMgmt` and `SqlServer` (22.0 or later) modules, and a Fabric administrator account for the organization-scoped inventory calls. You still need model permissions for sizing, even if you supply your own workspace IDs.

### 1. Set up PowerShell

Keep [PowerBI_Discovery_P_SKU.ps1](discovery/PowerBI_Discovery_P_SKU.ps1), [Export-SemanticModelSizes.ps1](discovery/Export-SemanticModelSizes.ps1), and [Invoke-DiscoveryRequest.ps1](discovery/Invoke-DiscoveryRequest.ps1) together in the `discovery` folder. If the modules are missing, install them from PowerShell 7:

```powershell
Install-Module MicrosoftPowerBIMgmt -Scope CurrentUser
Install-Module SqlServer -MinimumVersion 22.0 -Scope CurrentUser
```

### 2. Discover workspace names and IDs

If you already know the approved workspace IDs, skip to step 3. Otherwise, open PowerShell in the `discovery` folder, run the following command, and sign in to the correct tenant:

```powershell
.\PowerBI_Discovery_P_SKU.ps1
```

The discovery script writes two files at different stages:

| File | When and where it is written | How to use it |
|---|---|---|
| `XXXXWorkspacesT1.csv` | Written first, next to the script, after the initial workspace listing. | Starting list of IDs. **Do not run sizing on this file before reviewing it.** |
| `PowerBI-Discovery-Report-Active.csv` | Exported later, after collecting workspace details, in the current PowerShell directory. | Look up the `WorkspaceId` for each approved `WorkspaceName`. Check for errors or missing rows before relying on the report. |

Discovery defaults to active dedicated-capacity workspaces. Use `-IncludeSharedCapacity` only if you also want shared-capacity workspaces in the inventory; it does not make them eligible for XMLA sizing.

### 3. Prepare the ID list for sizing

Match your approved workspace names to IDs in the report. Open `XXXXWorkspacesT1.csv` in a text editor, or create it in `discovery` if it does not exist. Keep **only the approved IDs**, one per line under `WorkspaceId`. Leave out personal, admin, and system workspaces. Do not copy the entire report or include a name column.

```csv
WorkspaceId
11111111-1111-4111-8111-111111111111
22222222-2222-4222-8222-222222222222
```

If you already have `PowerBI-Discovery-Report-Active.csv` in `discovery`, you can also run [Copy-WorkspaceIds.ps1](discovery/Copy-WorkspaceIds.ps1) to extract the `WorkspaceId` column. It copies **every** ID in the report; it does not filter workspaces. Both the discovery script and this helper can overwrite the curated list, so review the file again after running either script.

### 4. Run the sizing export and read the results

From `discovery`, run the exporter and sign in when prompted. It processes only the IDs in `XXXXWorkspacesT1.csv`. To try one workspace first, add `-WorkspaceId '<GUID>'` using an ID already in the file.

```powershell
.\Export-SemanticModelSizes.ps1
```

Open `PowerBI-Discovery-SemanticModelSizes.csv` in `discovery` (separator: `;`). Filter to `SizeStatus = Estimated` and sort `EstimatedVertiPaqBytes` largest first.

| `SizeStatus` | Meaning |
|---|---|
| `Estimated` | Confirmed Import-only model with a positive estimate. |
| `Not measured` | Model did not have a confirmed Import-only partition mode. |
| `No size returned` | Confirmed Import-only, but the query did not return a usable positive size. |
| `Unavailable` | Mode inspection or sizing failed. Check the warning in PowerShell. |

If a listed workspace is no longer active or cannot be found, correct the ID list before retrying. The exporter has no model-name exclusion filter; leave any system-generated models out of your analysis.

## Option 2: Fabric Python notebook

**Prerequisites:** Access to create or import and run a PySpark notebook in a Fabric workspace on an active capacity. The notebook installs `semantic-link-labs==0.14.1`; your environment must allow that installation. For saved results, use an existing Lakehouse in the notebook's workspace that you can write to.

1. Import [Semantic Model Sizing Pilot.ipynb](discovery/Semantic%20Model%20Sizing%20Pilot.ipynb) into your Fabric workspace.
2. In the **configuration** cell, replace the sample workspace names with your own selection. Keep the existing exclusions and add tenant-specific admin workspaces to `EXCLUDE_WORKSPACE_NAMES` and system models to `EXCLUDE_MODEL_NAMES` or `EXCLUDE_MODEL_IDS`. For an ID-based selection and a display-only first run, use:

   ```python
   WORKSPACE_NAMES = []
   WORKSPACE_IDS = [
       "11111111-1111-4111-8111-111111111111",
       "22222222-2222-4222-8222-222222222222",
   ]
   STORAGE_MODES = ["Import"]
   OUTPUT_LAKEHOUSE = None
   ```

   For name-based selection, supply exact names in `WORKSPACE_NAMES` and leave `WORKSPACE_IDS` empty. If you fill both lists, the notebook includes matches from either list. **Do not leave both lists empty** for a targeted run: that scans all visible regular workspaces. Use IDs if names are duplicated.
3. Select **Run all**. With `OUTPUT_LAKEHOUSE = None`, review the displayed results and sort by `Estimated_VertiPaq_Bytes`. To save results, set `OUTPUT_LAKEHOUSE` to your Lakehouse name and rerun. The notebook **overwrites** `SemanticModelSizingPilot`; it does not change `SemanticModels`.
4. Check that the Import models you expected appear. With `STORAGE_MODES = ["Import"]`, a model is omitted if XMLA cannot determine its mode. If an expected model is missing, check its workspace visibility and permissions. You can also run a diagnostic pass with `STORAGE_MODES = []` and `OUTPUT_LAKEHOUSE = None` to see status details without replacing your saved results. Ignore `Observed_VertiPaq_Bytes` for non-Import models when choosing a SKU.

## Interpret the results and shortlist a SKU

The estimate adds **compressed dictionary bytes and used column-segment bytes** reported by VertiPaq. It is not PBIX file size, total model memory, or peak memory during refresh or queries. Direct Lake, DirectQuery, Dual, and mixed-mode models are outside this guide. A blank or missing size is **not zero**.

1. **Check coverage.** Reconcile the output with the Import models you expected in each workspace. Ask the workspace owner to confirm the mode of unresolved models. Investigate missing or failed measurements, especially for models likely to be large. For XMLA errors, verify the source capacity, tenant settings, permissions, and endpoint availability before retrying.
2. **Screen candidate SKUs.** Sort the measured Import models by size and compare the largest models individually with Microsoft's [semantic model memory limits by SKU](https://learn.microsoft.com/en-us/fabric/enterprise/powerbi/service-premium-what-is#semantic-model-sku-limitation). Allow room for data growth, refreshes, and queries. Do not choose an SKU just because the estimate is below its limit, and do not compare the sum of all model estimates with a per-model limit.
3. **Validate with a representative workload.** On the candidate SKU, test the largest models with realistic refresh schedules and concurrent report usage. Include other workloads that will share the capacity. Use the [Fabric Capacity Metrics app](https://learn.microsoft.com/en-us/fabric/enterprise/metrics-app) to check compute utilization and throttling, and verify that refreshes and queries finish successfully. See [Plan your capacity size](https://learn.microsoft.com/en-us/fabric/enterprise/plan-capacity) for guidance on shortlisting and testing SKUs.

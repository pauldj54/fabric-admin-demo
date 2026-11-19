"""Paste into a PySpark notebook in Microsoft Fabric and attach a default lakehouse.

Run as a Fabric administrator for tenant inventory. Sizing also requires XMLA
read access on a supported capacity and write permission on the semantic model
to run the read-only INFO queries. A tenant admin role alone does not grant this.

Set WORKSPACE_ID to a workspace GUID for a pilot run, or leave it as None for all
active, non-personal workspaces. Download the CSV from the lakehouse Files area.
Run large inventories off-peak: XMLA connections can cause models to load.

EstimatedVertiPaqBytes is the sum of dictionary and segment sizes for Import-only
models, not the offline file size or peak memory. Direct Lake, DirectQuery, and
mixed models stay in the inventory but are not assigned this estimate.
"""

import csv
from pathlib import Path
from uuid import UUID

from sempy import fabric
from sempy.fabric import admin

WORKSPACE_ID = None
OUTPUT = Path("/lakehouse/default/Files/PowerBI-Discovery-SemanticModelSizes.csv")

SIZE_QUERY = """
EVALUATE
ROW (
    "EstimatedBytes",
    SUMX ( INFO.STORAGETABLECOLUMNS(), [DICTIONARY_SIZE] )
        + SUMX ( INFO.STORAGETABLECOLUMNSEGMENTS(), [USED_SIZE] )
)
"""

COLUMNS = [
    "WorkspaceId", "WorkspaceName", "SemanticModelId", "SemanticModelName",
    "PartitionModes", "EstimatedVertiPaqBytes", "SizeStatus", "Details",
]


def export_sizes(workspace_id, output):
    if not output.parent.is_dir():
        raise RuntimeError("Attach a default lakehouse before running this notebook.")

    scope = UUID(workspace_id) if workspace_id else None
    workspaces = admin.list_workspaces(
        workspace=scope, workspace_state="Active", workspace_type="Workspace"
    )
    names = {UUID(str(row["Id"])): row["Name"] for row in workspaces.to_dict("records")}
    if scope and scope not in names:
        raise ValueError(f"{scope} was not found as an active, non-personal workspace.")

    models = admin.list_items(workspace=scope, item_type="SemanticModel", state="Active")
    total = measured = 0
    with output.open("w", newline="", encoding="utf-8-sig") as file:
        writer = csv.DictWriter(file, fieldnames=COLUMNS)
        writer.writeheader()
        for model in models.to_dict("records"):
            workspace = UUID(str(model["Workspace Id"]))
            if workspace not in names:
                continue
            dataset = UUID(str(model["Item Id"]))
            row = {
                "WorkspaceId": str(workspace),
                "WorkspaceName": names[workspace],
                "SemanticModelId": str(dataset),
                "SemanticModelName": model["Item Name"],
            }
            try:
                partitions = fabric.list_partitions(dataset=dataset, workspace=workspace)
                modes = sorted({str(mode) for mode in partitions["Mode"].dropna()})
                row["PartitionModes"] = "; ".join(modes)
                if modes == ["Import"]:
                    result = fabric.evaluate_dax(
                        dataset=dataset, workspace=workspace, dax_string=SIZE_QUERY
                    )
                    sizes = result.iloc[:, 0].dropna()
                    size = sizes.iloc[0] if not sizes.empty else 0
                    if size > 0:
                        row["EstimatedVertiPaqBytes"] = int(size)
                        row["SizeStatus"] = "Estimated"
                        measured += 1
                    else:
                        row.update(SizeStatus="No size returned", Details="No positive VertiPaq estimate.")
                else:
                    row.update(
                        SizeStatus="Not measured",
                        Details="This estimate is only reported for Import-only models.",
                    )
            except Exception as error:
                row.update(SizeStatus="Unavailable", Details=str(error))
                print(f"Could not size model {dataset} in workspace {workspace}: {error}")
            writer.writerow(row)
            total += 1

    print(f"Wrote {total} models ({measured} with estimates) to {output}")


export_sizes(WORKSPACE_ID, OUTPUT)

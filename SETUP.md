# Setup: deploying through Azure DevOps

Two Terraform layers, two pipelines.

| Layer | Applied by | Contains |
|---|---|---|
| `infra/bootstrap` | A person, once (needs Entra ID admin + subscription Owner) | Terraform state storage, Entra ID groups and sign-in app, pipeline identity (workload identity federation), empty app resource group, Key Vault, container registry, least-privilege RBAC |
| `infra` | `pipelines/infra.yml` | Azure OpenAI, AI Search, Container Apps, monitoring, managed identity and its role assignments |

| Pipeline | Runs when | Stages |
|---|---|---|
| `pipelines/infra.yml` | `infra/**` changes | Validate → Plan → **manual approval** → Apply |
| `pipelines/app.yml` | app, docs, scripts, eval or tests change | Test → Build image → Evaluate (quality gate) → Release |

The pipeline identity has **no Microsoft Graph permissions and no secret**. It is Contributor on one resource group, and may only create role assignments for six named roles there (an ABAC condition on Role Based Access Control Administrator).

## One-time setup

1. **Azure DevOps project** (private; the code itself is public on GitHub): pipelines read the GitHub repo through a GitHub connection, created when you add the first pipeline. Keep "Build pull requests from forks" off.

2. **Service connection, step 1**: Project settings → Service connections → New → Azure Resource Manager → Identity type **App registration or managed identity (manual)**, Credential **Workload identity federation**. Name it `sc-policy-assistant`. Enter your tenant ID and click Next: the draft is saved and shows the **Issuer** and **Subject identifier**. Put them in `infra/bootstrap/terraform.tfvars` (git-ignored) as `ado_wif_issuer` and `ado_wif_subject`.

3. **Bootstrap** (your machine, `az login` as an admin):
   ```bash
   terraform -chdir=infra/bootstrap init
   terraform -chdir=infra/bootstrap apply
   ```

4. **Service connection, step 2**: fill in the values from `terraform -chdir=infra/bootstrap output service_connection` (subscription, tenant, client ID), scope level Subscription, then **Verify and save**. Note the connection's ID (in its URL, `resourceId=`).

5. **Variable group** `policy-assistant` (Pipelines → Library): add every key from `terraform -chdir=infra/bootstrap output variable_group`, plus `serviceConnectionName` = `sc-policy-assistant` and `serviceConnectionId` = the ID from step 4. None are secrets.

6. **Environments** (Pipelines → Environments): `policy-assistant-demo` with an **Approvals** check (you), and `policy-assistant-demo-app` with no checks.

7. **Pipelines**: New pipeline → GitHub → this repo → Existing YAML → `pipelines/infra.yml`; repeat for `pipelines/app.yml`. Permit them to use the variable group, service connection and environments when first asked.

8. **First infra run**: run the infra pipeline, review the plan in the Plan stage log, approve.

9. **Sign-in redirect** (once): the sign-in app needs the Container Apps domain, which only exists after step 8.
   ```bash
   terraform -chdir=infra/bootstrap apply -var "redirect_domain=<sign-in redirect domain from the infra pipeline log>"
   ```

10. **First app run**: run the app pipeline. It indexes the policies, runs the evaluation set (fails the release on any wrong answer or HR leak) and rolls out the image. Open the app URL from the Release stage log.

## Switching the demo user between Staff and HR

```bash
terraform -chdir=infra/bootstrap apply ... -var 'demo_user_groups=["staff","hr"]'
```
Sign out and back in to the app to pick up the new group.

## Teardown

Destroy the main layer first (it lives in the bootstrap resource group), then the bootstrap:
```bash
az group delete -n rg-policy-assistant-demo --yes        # removes app resources, Key Vault, registry
terraform -chdir=infra/bootstrap destroy
```
Delete the service connection, variable group and environments in Azure DevOps afterwards.

## Things to check on the first run

- Terraform authenticates with the service connection through OIDC (`ARM_USE_OIDC`, `System.OidcRequestUri`). If your organisation restricts OIDC token requests to tasks, switch the Terraform steps to `AzureCLI@2` with `ARM_USE_CLI=true`.
- Azure AI Search free tier: one per subscription. If one already exists, change `sku` to `basic` (paid) or remove the other one.

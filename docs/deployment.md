# Deployment runbook

Region: `us-gov-west-1` · Account: `341370882819` (`aws-us-gov`)

## Prerequisites

- AWS CLI v2 authenticated as a principal that can create CFN/EC2/IAM/SSM
  resources in the account.
- **AWS Marketplace subscription accepted** for the **ZPA App Connector**
  product (code `by1wc5269g0048ix2nqvr0362`, AMI `ami-0205b8fb8ca4d9883`). See
  step 0 — this is a hard blocker; the ASG will not create until terms are
  accepted. NB: this is the ZPA App Connector, *not* the ZIA Cloud Connector
  (`i7l2axzva5jclhk90srmtkgv`, AMI `...pricpa...`) that was mistakenly used in
  the first attempt.
- `python3` on the deploy host (used by `deploy.sh` to expand params).

## 0. Accept the Marketplace subscription (one-time, REQUIRED)

The ZPA App Connector AMI (`ami-0205b8fb8ca4d9883`, `zpa-connector-el9-2026.05`)
is a public Marketplace image, but launching it requires the **account to have
accepted the product's terms**. Without this the connector stack fails at
`AppConnectorAsg` with:

> _"In order to use this AWS Marketplace product you need to accept terms and
> subscribe ... marketplace/pp?sku=<product-code>"_

This can't be done from the CLI — it's a console/EULA action:

1. In a browser, open the AWS Marketplace listing for the **ZPA App Connector**
   (product `by1wc5269g0048ix2nqvr0362`):
   `https://aws.amazon.com/marketplace/pp?sku=by1wc5269g0048ix2nqvr0362`
   Subscribe using the **commercial account linked to this GovCloud account** —
   GovCloud Marketplace entitlements are managed through the paired standard
   account. **Confirm the listing title says ZPA App Connector** (not ZIA Cloud
   Connector, Private Service Edge, etc.).
2. Click **Continue to Subscribe** → **Accept Terms**. Wait until the
   subscription shows active.
3. Confirm the AMI is now launchable, then proceed to step 1 below.

Verify (the product code is present on the AMI regardless; the gate is the
*subscription* state, which surfaces only at launch/ASG-create time):

```bash
aws ec2 describe-images --region us-gov-west-1 --image-ids ami-0205b8fb8ca4d9883 \
  --query 'Images[0].{Name:Name,ProductCodes:ProductCodes}' --output json
```

> Other ZPA images visible in the account (do **not** use for App Connectors):
> `zpa-service-edge` (Private Service Edge), `zpa-pcc` (Private Cloud Controller),
> `zpa-network-connector` (older build). The App Connector is `zpa-connector-el9`.

## Order of operations

```
1. network      → creates the two /28 subnets (+ exports)
2. (phase 2)    → create ZPA provisioning key, store in SSM   ← see step 3
3. connectors   → SG, IAM, launch template, ASG
```

You *can* deploy `connectors` before the provisioning key exists — the stack will
build fine, but the instances will fail to enroll and log
`could not read provisioning key` until the SSM parameter is populated. To avoid
churn, create the key first (step 3 below) when you're ready to actually enroll.

## 1. Validate (optional)

```bash
./scripts/deploy.sh validate
```

## 2. Deploy the network stack

```bash
./scripts/deploy.sh network
```

This creates `zpa-appconnector-private-1a/1b` and associates them with the
existing private route table. Verify:

```bash
aws ec2 describe-subnets --region us-gov-west-1 \
  --filters Name=tag:Project,Values=zscaler-app-connectors \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,Cidr:CidrBlock,AZ:AvailabilityZone}' \
  --output table
```

## 3. Create & store the ZPA provisioning key (before enrolling)

Get a provisioning key from the ZPA Admin Portal (or the API — see
[zscaler-api.md](zscaler-api.md)), then store it as a SecureString:

```bash
aws ssm put-parameter --region us-gov-west-1 \
  --name "/zscaler/zpa/provisioning-key" \
  --type SecureString \
  --value "<PROVISIONING_KEY>" \
  --overwrite
```

(Default uses the AWS-managed `alias/aws/ssm` key; the instance role's
`kms:Decrypt` is scoped via `kms:ViaService=ssm.us-gov-west-1.amazonaws.com`.)

## 4. Deploy the connector stack

```bash
./scripts/deploy.sh connectors
```

Watch the ASG bring up two instances:

```bash
aws autoscaling describe-auto-scaling-groups --region us-gov-west-1 \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName,'zpa-app-connectors')].Instances[].{Id:InstanceId,AZ:AvailabilityZone,Health:HealthStatus,State:LifecycleState}" \
  --output table
```

## 5. Verify enrollment

- **In AWS** — check the bootstrap log via SSM Session Manager:
  ```bash
  aws ssm start-session --region us-gov-west-1 --target <instance-id>
  sudo tail -n 50 /var/log/zpa-userdata.log
  sudo systemctl status zpa-connector
  ```
- **In Zscaler** — the two connectors appear (and go green/healthy) under the
  connector group in the ZPA Admin Portal / via the API.

## Updating connectors (new AMI / version)

1. Bump `AppConnectorAmiId` in `cloudformation/params/02-app-connectors.params.json`.
2. `./scripts/deploy.sh connectors` — the rolling-update policy replaces
   instances one at a time (`MinInstancesInService=1`), so service stays up.
3. Prune the now-orphaned old connectors in the ZPA portal/API.

## Rollback / teardown

```bash
# Compute first (depends on network exports), then network.
aws cloudformation delete-stack --region us-gov-west-1 --stack-name zpa-app-connectors
aws cloudformation wait stack-delete-complete --region us-gov-west-1 --stack-name zpa-app-connectors
aws cloudformation delete-stack --region us-gov-west-1 --stack-name zpa-network
```

Deleting the network stack will fail while the connector stack still imports its
exports — delete `zpa-app-connectors` first. The SSM provisioning-key parameter
is **not** managed by these stacks; remove it separately if desired.

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `could not read provisioning key` in `/var/log/zpa-userdata.log` | SSM param missing/misnamed, or role can't decrypt. Confirm `/zscaler/zpa/provisioning-key` exists as SecureString. |
| Instances never reach the Zscaler cloud | Egress path — confirm the new subnets are on `rtb-07aa95919af0e668f` and the NAT GW is `available`. |
| Connector enrolls then drops | Provisioning key exhausted/expired, or duplicate enrollment from ASG churn. Rotate key; prune stale connectors. |
| `delete-stack` on network fails | Connector stack still exists (import dependency). Delete it first. |

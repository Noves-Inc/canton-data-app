# Canton Data App

## Overview

Welcome to the Canton Data App, by Noves.

This is a self-hosted application that takes care of sourcing, indexing, processing and visualizing your Canton data for a variety of reporting scenarios and use cases.

Because it runs in your infrastructure and uses your existing authentication system, it allows you to maintain full security and privacy, as intended in the Canton Network's design philosophy, while still enabling a superior data UX.

## Components

It consists of two primary components:

- Backend indexer/processor: The backend indexes your data, contextualizes it with its real-world meaning, and delivers it in an enriched JSON format that's easily consumed by other applications for financial reporting and other purposes. The JSON schema for Canton transactions is similar to the one we use for reporting on other blockchains (see [docs.noves.fi](https://docs.noves.fi) for more). It's intended to capture the full breadth of relevant details, while simplifying and interpreting a lot of the complexity that comes with raw data.

- Dashboard: The frontend consists of a dashboard that runs on backend-provided data. It allows you to visualize the data in multiple views, filter it by various conditions, graph it, and export it to CSV.

## Deployment

### Initial considerations

The delivery of the app is through two Docker containers, that are assumed to be running in the same network (as part of a docker-compose deployment if you're deploying in a VM, or as two separate Kubernetes deployments in the same namespace, if you're deploying in k8s).

Both containers are stateful, meaning that they have local storage that needs to persist across restarts. We include the exact paths on which a volume or PVC needs to be mounted in the sample manifests.

It is not a requirement that they run in the same network as your Canton validator node. But in practice, we expect this to be the case most of the time (for your own security). All URLs and endpoints are configurable via environment variables.

### Requirements

The backend will need network access to the Ledger API on your validator node.

We assume that the traffic between the backend container and Ledger API will be encrypted, so we have planned for a certificate to be mounted to the container so that it can authenticate secure gRPC requests against the Ledger API.

On your validator node, if not done already, you will need to expose a port for the gRPC Ledger API, and (optionally) enable TLS. We're including exact instructions on how to do this, in a separate file.

For hardware, plan to allocate roughly this for each container:
- Backend container
- Frontend container

### Authentication 

This app leverages your existing authentication system, instead of requiring a new one.

In the current version, the frontend ships native support for Auth0 authentication (Keycloak support coming soon).

The backend will always work with any authentication system that is compatible with Canton's JWT standard.

If you're using the frontend to query the data, you'll sign in with essentially the same flow as logging in to the native Canton Wallet:

- You log in with your user account, which has already been authorized for one or more parties, and the frontend will get a JWT token issued via Auth0 and send that token to the backend, which will retrieve data for the parties you're authorized to read.

For larger organizations, this means that users can only access data for parties that they have previously been granted access to.

## Installation steps

- If you're running your node on a docker-compose environment, refer to the `docker_compose_deployment.md` file for step-by-step instructions
- For a Kubernetes deployment, refer to `kubernetes_deployment.md`

## Support

This is an early-stage product in a nascent ecosystem. It's likely that issues will arise, and we're looking forward to helping in any way we can.

If you spot any issues or run into a snag during deployment, contact us through our shared Slack channel (if you don't have a channel with us yet, just ask).

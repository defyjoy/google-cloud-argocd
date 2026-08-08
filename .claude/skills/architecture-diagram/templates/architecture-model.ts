/**

* Reusable architecture diagram data model.
*
* Claude should copy and adapt this file into the target repository rather
* than importing it directly from the Claude skill directory.
*
* Keep architecture data separate from SVG, React Flow or layout rendering.
  */

export type ArchitectureNodeCategory =
| "actor"
| "client"
| "edge"
| "gateway"
| "application"
| "worker"
| "platform"
| "security"
| "database"
| "cache"
| "messaging"
| "storage"
| "observability"
| "cicd"
| "external";

export type ArchitectureBoundaryType =
| "organisation"
| "cloud"
| "account"
| "project"
| "subscription"
| "region"
| "availability-zone"
| "network"
| "subnet"
| "cluster"
| "namespace"
| "environment"
| "domain"
| "tenant"
| "trust-zone"
| "custom";

export type ArchitectureConnectionType =
| "synchronous"
| "asynchronous"
| "authentication"
| "control-plane"
| "telemetry"
| "replication"
| "administrative"
| "fallback"
| "unknown";

export type ArchitectureConfidence =
| "confirmed"
| "strongly-inferred"
| "planned"
| "unverified"
| "contradictory";

export type ArchitectureEnvironment =
| "local"
| "development"
| "test"
| "staging"
| "production"
| "shared"
| "management"
| "disaster-recovery"
| "external"
| string;

export type ArchitecturePortSide = "top" | "right" | "bottom" | "left";

export type ArchitectureNodeSize = "small" | "medium" | "large" | "custom";

export type ArchitectureRiskLevel =
| "informational"
| "low"
| "medium"
| "high"
| "critical";

export interface ArchitectureEvidence {
/**

* Repository containing the supporting evidence.
*
* Example:
* "alarmify-ingest-api"
  */
  repository?: string;

/**

* Path relative to the repository root.
*
* Example:
* "internal/http/router.go"
  */
  filePath?: string;

/**

* Optional line range or symbol.
*
* Example:
* "lines 42-78"
* "NewRouter()"
* "kind: HTTPRoute"
  */
  location?: string;

/**

* Concise description of what the evidence proves.
  */
  description: string;

/**

* Optional documentation URL or repository-local documentation path.
  */
  reference?: string;
  }

export interface ArchitectureRisk {
id: string;
title: string;
description: string;
level: ArchitectureRiskLevel;

/**

* Node or connection IDs affected by this risk.
  */
  relatedElementIds?: string[];

/**

* Suggested mitigation or next investigative step.
  */
  mitigation?: string;
  }

export interface ArchitectureQuestion {
id: string;
question: string;

/**

* Why the answer matters to the architecture.
  */
  impact?: string;

/**

* Repository, configuration, runtime command or owner that may answer it.
  */
  suggestedSource?: string;

status?: "open" | "answered" | "deferred";
answer?: string;
}

export interface ArchitecturePort {
id: string;
side: ArchitecturePortSide;

/**

* Offset from 0 to 1 along the selected node side.
*
* Example:
* 0.5 means the middle of the side.
  */
  offset?: number;

/**

* Optional semantic role.
*
* Examples:
* "http-in"
* "events-out"
* "telemetry-out"
  */
  role?: string;

label?: string;
}

export interface ArchitecturePosition {
x: number;
y: number;
}

export interface ArchitectureDimensions {
width: number;
height: number;
}

export interface ArchitectureNode {
id: string;
name: string;
category: ArchitectureNodeCategory;

/**

* Short responsibility shown in the node.
  */
  description: string;

/**

* Longer explanation for the details panel.
  */
  details?: string;

/**

* Primary implementation technologies.
*
* Example:
* ["Go", "Gin", "PostgreSQL"]
  */
  technologies?: string[];

environment?: ArchitectureEnvironment;

/**

* Cloud, cluster, namespace or physical runtime location.
  */
  runtimeLocation?: string;

/**

* Parent boundary ID.
  */
  parentId?: string;

repository?: string;
sourceFiles?: string[];

confidence: ArchitectureConfidence;
evidence?: ArchitectureEvidence[];

/**

* Human-readable tags used for search and filtering.
  */
  tags?: string[];

/**

* Icon identifier consumed by the target application's icon resolver.
*
* Examples:
* "server"
* "database"
* "kubernetes"
* "aws-lambda"
  */
  icon?: string;

position: ArchitecturePosition;
size?: ArchitectureNodeSize;
dimensions?: ArchitectureDimensions;

ports?: ArchitecturePort[];

optional?: boolean;
hiddenByDefault?: boolean;

risks?: ArchitectureRisk[];
openQuestions?: ArchitectureQuestion[];

metadata?: Record<string, string | number | boolean | string[]>;
}

export interface ArchitectureBoundary {
id: string;
name: string;
type: ArchitectureBoundaryType;

description?: string;
parentId?: string;
environment?: ArchitectureEnvironment;

position: ArchitecturePosition;
dimensions: ArchitectureDimensions;

confidence?: ArchitectureConfidence;
evidence?: ArchitectureEvidence[];

tags?: string[];
icon?: string;

/**

* Optional metadata shown near the boundary heading.
*
* Examples:
* "europe-west1"
* "10.20.0.0/16"
* "Private"
  */
  subtitle?: string;

metadata?: Record<string, string | number | boolean | string[]>;
}

export interface ArchitectureConnectionEndpoint {
nodeId: string;
portId?: string;
}

export interface ArchitectureConnection {
id: string;

source: ArchitectureConnectionEndpoint;
target: ArchitectureConnectionEndpoint;

type: ArchitectureConnectionType;

/**

* Short label shown directly on the connector.
*
* Examples:
* "HTTPS"
* "NATS: events.raw"
* "OTLP/gRPC"
  */
  label?: string;

/**

* Detailed explanation shown in the inspection panel.
  */
  description?: string;

protocol?: string;
port?: number | string;

communicationMode?: "synchronous" | "asynchronous" | "streaming";

authentication?: string;

/**

* Concise description of the transferred payload.
  */
  dataTransferred?: string;

retryBehaviour?: string;
failureBehaviour?: string;

confidence: ArchitectureConfidence;
evidence?: ArchitectureEvidence[];

/**

* Optional manually controlled intermediate points for SVG routing.
  */
  waypoints?: ArchitecturePosition[];

/**

* Used when the edge is optional, degraded, fallback or conditional.
  */
  optional?: boolean;

bidirectional?: boolean;

tags?: string[];
risks?: ArchitectureRisk[];
openQuestions?: ArchitectureQuestion[];

metadata?: Record<string, string | number | boolean | string[]>;
}

export interface ArchitectureLegendItem {
id: string;
label: string;
description?: string;

nodeCategory?: ArchitectureNodeCategory;
connectionType?: ArchitectureConnectionType;
confidence?: ArchitectureConfidence;
}

export interface ArchitectureFilterDefinition {
id: string;
label: string;
type:
| "environment"
| "node-category"
| "connection-type"
| "confidence"
| "tag"
| "custom";

options: Array<{
value: string;
label: string;
defaultEnabled?: boolean;
}>;
}

export interface ArchitectureView {
id: string;
name: string;
description: string;

/**

* The architectural question answered by this view.
  */
  purpose: string;

audience?: string[];

nodeIds: string[];
boundaryIds: string[];
connectionIds: string[];

/**

* Initial viewport state.
  */
  viewport?: {
  x: number;
  y: number;
  zoom: number;
  };

filters?: ArchitectureFilterDefinition[];

/**

* Optional node to select when the view first opens.
  */
  initialSelectedNodeId?: string;
  }

export interface ArchitectureSource {
id: string;
name: string;
type:
| "repository"
| "documentation"
| "api-specification"
| "database-schema"
| "runtime-output"
| "diagram"
| "interview"
| "other";

location?: string;
description?: string;

/**

* Whether the source was actually inspected.
  */
  inspected: boolean;

/**

* Optional reason when the source could not be inspected.
  */
  unavailableReason?: string;
  }

export interface ArchitectureModel {
id: string;
title: string;
description: string;

/**

* Architecture question or decision the model is intended to explain.
  */
  purpose: string;

audience: string[];

version: string;
generatedAt: string;

sources: ArchitectureSource[];

nodes: ArchitectureNode[];
boundaries: ArchitectureBoundary[];
connections: ArchitectureConnection[];

views: ArchitectureView[];
legend?: ArchitectureLegendItem[];

risks?: ArchitectureRisk[];
openQuestions?: ArchitectureQuestion[];

metadata?: {
organisation?: string;
system?: string;
owner?: string;
repository?: string;
defaultViewId?: string;
[key: string]: string | number | boolean | string[] | undefined;
};
}

/**

* Minimal example.
*
* Replace this example with architecture data discovered from the target
* repositories and documentation.
  */
  export const architectureModelExample: ArchitectureModel = {
  id: "example-platform-architecture",
  title: "Example platform architecture",
  description:
  "A minimal model demonstrating boundaries, nodes, connections and evidence.",
  purpose:
  "Explain how external traffic reaches an application and its database.",
  audience: ["Engineering", "Platform", "Security"],
  version: "1.0.0",
  generatedAt: new Date().toISOString(),

sources: [
{
id: "source-application-repository",
name: "example-api",
type: "repository",
location: "repositories/example-api",
description: "Application source and API configuration.",
inspected: true,
},
{
id: "source-gitops-repository",
name: "example-gitops",
type: "repository",
location: "repositories/example-gitops",
description: "Kubernetes manifests and deployment configuration.",
inspected: true,
},
],

boundaries: [
{
id: "boundary-cloud-project",
name: "Production cloud project",
type: "project",
description: "Production cloud resources.",
environment: "production",
position: {
x: 260,
y: 80,
},
dimensions: {
width: 980,
height: 620,
},
subtitle: "Private production environment",
},
{
id: "boundary-kubernetes-cluster",
name: "Application Kubernetes cluster",
type: "cluster",
description: "Production Kubernetes runtime.",
parentId: "boundary-cloud-project",
environment: "production",
position: {
x: 360,
y: 170,
},
dimensions: {
width: 560,
height: 420,
},
subtitle: "Kubernetes",
},
],

nodes: [
{
id: "node-user",
name: "Platform user",
category: "actor",
description: "Uses the web application.",
confidence: "confirmed",
position: {
x: 40,
y: 270,
},
size: "small",
ports: [
{
id: "user-http-out",
side: "right",
role: "http-out",
},
],
tags: ["user", "external"],
},
{
id: "node-ingress",
name: "Ingress gateway",
category: "gateway",
description: "Terminates external HTTPS traffic.",
technologies: ["Kubernetes Gateway API"],
environment: "production",
runtimeLocation: "Application Kubernetes cluster",
parentId: "boundary-kubernetes-cluster",
repository: "example-gitops",
sourceFiles: ["clusters/production/gateway.yaml"],
confidence: "confirmed",
evidence: [
{
repository: "example-gitops",
filePath: "clusters/production/gateway.yaml",
location: "kind: Gateway",
description:
"Defines the production Gateway API ingress resource.",
},
],
position: {
x: 420,
y: 280,
},
ports: [
{
id: "ingress-http-in",
side: "left",
role: "http-in",
},
{
id: "ingress-http-out",
side: "right",
role: "http-out",
},
],
tags: ["gateway", "kubernetes", "production"],
},
{
id: "node-api",
name: "Application API",
category: "application",
description: "Processes user and domain requests.",
technologies: ["TypeScript", "Node.js"],
environment: "production",
runtimeLocation: "Application Kubernetes cluster",
parentId: "boundary-kubernetes-cluster",
repository: "example-api",
sourceFiles: ["src/server.ts", "src/routes/index.ts"],
confidence: "confirmed",
evidence: [
{
repository: "example-api",
filePath: "src/server.ts",
location: "createServer()",
description: "Creates the application HTTP server.",
},
],
position: {
x: 650,
y: 280,
},
ports: [
{
id: "api-http-in",
side: "left",
role: "http-in",
},
{
id: "api-database-out",
side: "right",
role: "database-out",
},
],
tags: ["api", "application", "production"],
},
{
id: "node-database",
name: "PostgreSQL",
category: "database",
description: "Stores transactional application data.",
technologies: ["PostgreSQL"],
environment: "production",
runtimeLocation: "Managed database service",
parentId: "boundary-cloud-project",
confidence: "strongly-inferred",
evidence: [
{
repository: "example-api",
filePath: "src/config/database.ts",
description:
"Configures a PostgreSQL application connection string.",
},
],
position: {
x: 1020,
y: 280,
},
size: "datastore" as ArchitectureNodeSize,
ports: [
{
id: "database-sql-in",
side: "left",
role: "sql-in",
},
],
tags: ["postgresql", "database", "production"],
},
],

connections: [
{
id: "connection-user-to-ingress",
source: {
nodeId: "node-user",
portId: "user-http-out",
},
target: {
nodeId: "node-ingress",
portId: "ingress-http-in",
},
type: "synchronous",
label: "HTTPS",
protocol: "HTTPS",
port: 443,
communicationMode: "synchronous",
dataTransferred: "Browser requests and responses",
confidence: "confirmed",
},
{
id: "connection-ingress-to-api",
source: {
nodeId: "node-ingress",
portId: "ingress-http-out",
},
target: {
nodeId: "node-api",
portId: "api-http-in",
},
type: "synchronous",
label: "HTTP",
protocol: "HTTP",
communicationMode: "synchronous",
dataTransferred: "Application API requests",
confidence: "confirmed",
},
{
id: "connection-api-to-database",
source: {
nodeId: "node-api",
portId: "api-database-out",
},
target: {
nodeId: "node-database",
portId: "database-sql-in",
},
type: "synchronous",
label: "PostgreSQL",
protocol: "PostgreSQL wire protocol",
port: 5432,
communicationMode: "synchronous",
authentication: "Database credentials from secret management",
dataTransferred: "Transactional reads and writes",
confidence: "strongly-inferred",
},
],

views: [
{
id: "view-system-overview",
name: "System overview",
description:
"Shows the user request path through ingress, application and persistence.",
purpose: "Explain the primary production request path.",
audience: ["Engineering", "Platform", "Security"],
nodeIds: [
"node-user",
"node-ingress",
"node-api",
"node-database",
],
boundaryIds: [
"boundary-cloud-project",
"boundary-kubernetes-cluster",
],
connectionIds: [
"connection-user-to-ingress",
"connection-ingress-to-api",
"connection-api-to-database",
],
viewport: {
x: 0,
y: 0,
zoom: 1,
},
},
],

legend: [
{
id: "legend-application",
label: "Application service",
nodeCategory: "application",
},
{
id: "legend-database",
label: "Database",
nodeCategory: "database",
},
{
id: "legend-synchronous",
label: "Synchronous request",
connectionType: "synchronous",
},
{
id: "legend-inferred",
label: "Strongly inferred from implementation",
confidence: "strongly-inferred",
},
],

risks: [],
openQuestions: [],

metadata: {
system: "Example platform",
defaultViewId: "view-system-overview",
},
};

/**

* Runtime validation helpers.
*
* These are intentionally dependency-free. The target project may replace
* them with Zod, Valibot or another existing validation library.
  */
  export function validateArchitectureModel(
  model: ArchitectureModel,
  ): string[] {
  const errors: string[] = [];

const nodeIds = new Set(model.nodes.map((node) => node.id));
const boundaryIds = new Set(
model.boundaries.map((boundary) => boundary.id),
);
const connectionIds = new Set(
model.connections.map((connection) => connection.id),
);

for (const node of model.nodes) {
if (node.parentId && !boundaryIds.has(node.parentId)) {
errors.push(
`Node "${node.id}" references missing boundary "${node.parentId}".`,
);
}
}

for (const boundary of model.boundaries) {
if (boundary.parentId && !boundaryIds.has(boundary.parentId)) {
errors.push(
`Boundary "${boundary.id}" references missing parent boundary "${boundary.parentId}".`,
);
}
}

for (const connection of model.connections) {
if (!nodeIds.has(connection.source.nodeId)) {
errors.push(
`Connection "${connection.id}" references missing source node "${connection.source.nodeId}".`,
);
}

```
if (!nodeIds.has(connection.target.nodeId)) {
  errors.push(
    `Connection "${connection.id}" references missing target node "${connection.target.nodeId}".`,
  );
}

if (connection.source.nodeId === connection.target.nodeId) {
  errors.push(
    `Connection "${connection.id}" connects a node to itself.`,
  );
}
```

}

for (const view of model.views) {
for (const nodeId of view.nodeIds) {
if (!nodeIds.has(nodeId)) {
errors.push(
`View "${view.id}" references missing node "${nodeId}".`,
);
}
}

```
for (const boundaryId of view.boundaryIds) {
  if (!boundaryIds.has(boundaryId)) {
    errors.push(
      `View "${view.id}" references missing boundary "${boundaryId}".`,
    );
  }
}

for (const connectionId of view.connectionIds) {
  if (!connectionIds.has(connectionId)) {
    errors.push(
      `View "${view.id}" references missing connection "${connectionId}".`,
    );
  }
}
```

}

return errors;
}

export function getNodeById(
model: ArchitectureModel,
nodeId: string,
): ArchitectureNode | undefined {
return model.nodes.find((node) => node.id === nodeId);
}

export function getIncomingConnections(
model: ArchitectureModel,
nodeId: string,
): ArchitectureConnection[] {
return model.connections.filter(
(connection) => connection.target.nodeId === nodeId,
);
}

export function getOutgoingConnections(
model: ArchitectureModel,
nodeId: string,
): ArchitectureConnection[] {
return model.connections.filter(
(connection) => connection.source.nodeId === nodeId,
);
}

export function getConnectedNodeIds(
model: ArchitectureModel,
nodeId: string,
): Set<string> {
const connectedNodeIds = new Set<string>();

for (const connection of model.connections) {
if (connection.source.nodeId === nodeId) {
connectedNodeIds.add(connection.target.nodeId);
}

```
if (connection.target.nodeId === nodeId) {
  connectedNodeIds.add(connection.source.nodeId);
}
```

}

return connectedNodeIds;
}

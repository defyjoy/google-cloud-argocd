---

name: architecture-diagram
description: Investigate repositories and documentation, then create polished interactive software architecture diagrams using React, TypeScript and SVG. Use when the user asks for a system-design diagram, cloud architecture, Kubernetes topology, service map, data flow, request flow, deployment diagram, security boundary diagram, or architecture visualization. Never use Mermaid, PlantUML, Graphviz or ASCII unless explicitly requested.
argument-hint: "[diagram goal or architecture question]"
disable-model-invocation: true
------------------------------

# Interactive Architecture Diagram Skill

Act as a senior software architect, repository investigator, information designer and frontend visualization engineer.

Your task is to investigate the supplied software system and create a polished, professional and interactive architecture diagram.

The final diagram must be implemented using:

* React
* TypeScript
* Native SVG
* Existing project CSS or Tailwind CSS
* React Flow only when graph interaction genuinely requires it

Never generate Mermaid, PlantUML, Graphviz DOT, ASCII diagrams, Markdown diagrams, or a frontend wrapper around Mermaid unless the user explicitly requests one.

## User request

$ARGUMENTS

## Mandatory first step

Before investigating or generating the diagram, determine which repositories and documentation sources are available.

Ask the user to provide or identify:

1. Application repositories
2. Infrastructure or Terraform repositories
3. Helm chart or Kubernetes repositories
4. GitOps repositories
5. Architecture documentation repositories
6. API specifications
7. Database schemas
8. Deployment documentation
9. Existing diagrams or screenshots
10. Cloud provider and runtime environments

Also ask:

* What architectural question should the diagram answer?
* Who is the intended audience?
* Should this be an overview, deep technical view, or both?

Do not begin diagram implementation until the relevant sources have been identified.

Do not ask again for information already present in the conversation or repository.

## Repository investigation

Inspect actual implementation evidence rather than relying only on README files or directory names.

Investigate:

* Runtime services
* API boundaries
* Service-to-service communication
* External entry points
* Authentication and authorization
* Databases and storage systems
* Queues, streams and event buses
* Kubernetes clusters and namespaces
* Cloud accounts, projects and regions
* VPC and network boundaries
* CI/CD and GitOps flows
* Observability components
* Security boundaries
* Tenant boundaries
* Cross-cluster communication
* Synchronous and asynchronous paths
* Retry, failure and fallback paths
* External integrations

Search relevant source files, configuration files, manifests, Terraform modules, Helm values, API specifications and documentation.

For important findings, retain supporting evidence such as:

* Repository
* File path
* Configuration section
* Resource name
* API route
* Kubernetes object
* Terraform resource
* Documentation section

Never invent a component or relationship merely to make the diagram look complete.

## Confidence model

Classify architecture findings as:

* Confirmed
* Strongly inferred
* Planned
* Unverified
* Contradictory

Represent uncertain connections with dashed edges or visible uncertainty markers.

Maintain an assumptions and unresolved-questions section.

## Diagram planning

Before coding, provide a concise investigation summary and propose the diagram views.

Select from:

* System context
* Container architecture
* Component architecture
* Cloud infrastructure
* Kubernetes multi-cluster topology
* Deployment topology
* Request flow
* Data flow
* Event-driven architecture
* Authentication sequence
* CI/CD and GitOps flow
* Security trust boundaries
* Observability pipeline
* Disaster-recovery topology

Do not force a large system into one unreadable canvas.

For complex systems, prefer:

1. Executive overview
2. Detailed infrastructure or application view
3. Critical request or event-flow view

## Structured diagram model

Create a typed data model before implementing the visual rendering.

Each node should include:

* Stable ID
* Display name
* Category
* Responsibility
* Technology
* Environment
* Runtime location
* Repository
* Relevant source files
* Confidence level
* Optional risks
* Optional unresolved questions

Each connection should include:

* Stable ID
* Source
* Destination
* Direction
* Protocol
* Port when known
* Synchronous or asynchronous
* Authentication mechanism
* Data transferred
* Retry behaviour
* Failure behaviour
* Confidence level
* Optional evidence

Groups and boundaries should represent relevant architecture constructs such as:

* Cloud account or project
* Region
* VPC
* Network
* Kubernetes cluster
* Namespace
* Application domain
* Environment
* Trust zone
* Tenant boundary

Use the structured model as the source of truth for rendering.

## Visual design requirements

Create a premium presentation-quality design.

Use:

* Clear visual hierarchy
* Rounded architecture cards
* Subtle borders and shadows
* Consistent spacing
* Consistent typography
* Semantic colour usage
* Clearly labelled boundaries
* Deliberate connector routing
* Directional arrowheads
* Compact protocol labels
* Recognisable technology icons where available
* A concise legend
* Light and dark mode compatibility

Avoid:

* Random positioning
* Decorative clutter
* Excessive gradients
* Tiny text
* Oversized nodes
* Long paragraphs inside nodes
* Unexplained abbreviations
* Excessive connector crossings
* Connectors running through nodes
* Generic placeholder icons
* Unnecessary animations

Use colour consistently for categories such as:

* Users and clients
* Edge and ingress
* Application services
* Platform services
* Databases
* Messaging
* Security
* Observability
* External systems

## Layout requirements

Choose a layout direction that matches the architecture:

* Left to right for request flow
* Top to bottom for layered systems
* Outside to inside for trust zones
* Columns for clusters or environments
* Swimlanes for teams or responsibilities

Use deterministic positions.

Use deliberate connection ports on node edges.

Where many edges share the same route, use an aggregation node, event bus, gateway or labelled connection lane instead of creating an unreadable web of lines.

## Connector semantics

Visually distinguish:

* Synchronous API requests
* Asynchronous events
* Control-plane communication
* Authentication flows
* Observability telemetry
* Replication
* Administrative communication
* Optional or fallback paths
* Unverified relationships

Every relevant edge should communicate:

* Direction
* Protocol or event
* Sync or async behaviour
* Source
* Destination

Do not label every edge when labels would create clutter. Provide detail in the node or edge inspection panel where appropriate.

## Interactivity

Implement useful interactions where appropriate:

* Zoom
* Pan
* Fit to screen
* Reset view
* Full-screen mode
* Search
* Component filters
* Environment filters
* Communication-type filters
* Show or hide optional infrastructure
* Show or hide edge labels
* Node hover state
* Node selection
* Highlight incoming dependencies
* Highlight outgoing dependencies
* Dim unrelated components
* Expand or collapse groups
* SVG export
* PNG export

When a node is selected, show a details panel containing:

* Name
* Responsibility
* Technology
* Runtime location
* Repository
* Source files
* Dependencies
* Protocols
* Authentication
* Confidence level
* Risks
* Unresolved questions

## Implementation structure

First inspect the existing repository for:

* Framework
* Package manager
* Routing
* Styling system
* Component library
* Icon library
* Existing visualization dependencies
* Testing conventions
* Linting and formatting commands

Reuse existing libraries and conventions where practical.

Before installing a dependency, verify that the repository does not already provide equivalent functionality.

Prefer a structure similar to:

```text
src/
  components/
    architecture/
      ArchitectureCanvas.tsx
      ArchitectureNode.tsx
      ArchitectureBoundary.tsx
      ArchitectureEdge.tsx
      ArchitectureToolbar.tsx
      ArchitectureLegend.tsx
      ArchitectureDetailsPanel.tsx
  data/
    architecture-model.ts
  layout/
    architecture-layout.ts
  pages/
    ArchitectureDiagramPage.tsx
```

Keep data, layout calculations and rendering logic separate.

Do not implement the entire diagram in one large component.

Use typed interfaces and reusable components.

## Technology decision

Prefer native SVG when:

* The diagram is presentation-oriented
* Precise visual control matters
* Positions are mostly deterministic
* Export quality matters
* Custom boundaries and connectors are important

Use React Flow when:

* The graph is large
* Users need to drag nodes
* Dependency exploration is central
* Built-in viewport management is beneficial
* Edge routing and graph interaction would otherwise become unnecessarily complex

When using React Flow, create custom nodes and custom edges. Do not accept its default visual appearance as the final design.

## Validation

After implementation:

1. Run formatting.
2. Run linting.
3. Run TypeScript checking.
4. Run relevant tests.
5. Build or start the application.
6. Inspect the rendered result.
7. Check for overlapping nodes.
8. Check for clipped labels.
9. Check connector routing.
10. Check light and dark modes.
11. Check responsive behaviour.
12. Check keyboard accessibility.
13. Fix visible issues before reporting completion.

Do not claim commands passed unless they were actually executed successfully.

## Final response

Report:

1. Architecture summary
2. Sources inspected
3. Confirmed findings
4. Inferred findings
5. Unverified relationships
6. Diagram views created
7. Files created
8. Files modified
9. Dependencies added
10. Validation commands and results
11. Remaining limitations
12. How to open the diagram

Do not commit, push, deploy or modify unrelated code unless explicitly instructed.

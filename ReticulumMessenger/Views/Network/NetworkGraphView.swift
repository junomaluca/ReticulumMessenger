// SPDX-License-Identifier: MIT
// ReticulumMessenger — NetworkGraphView.swift

import SwiftUI

/// Interactive mesh network topology visualization.
struct NetworkGraphView: View {
    @EnvironmentObject var appState: AppState
    @State private var nodes: [GraphNode] = []
    @State private var edges: [GraphEdge] = []
    @State private var animationPhase: CGFloat = 0
    @State private var selectedNode: GraphNode?
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            GeometryReader { geo in
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate
                    let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: 3.0) / 3.0)
                    Canvas { context, size in
                        animationPhase = phase
                        drawGrid(context: context, size: size)
                        drawEdges(context: context, size: size)
                        drawNodes(context: context, size: size)
                        drawPacketParticles(context: context, size: size)
                    }
                }
                .onAppear {
                    canvasSize = geo.size
                    buildGraph()
                }
                .onChange(of: appState.interfaces.count) { _, _ in buildGraph() }
                .onChange(of: appState.knownPeers.count) { _, _ in buildGraph() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        selectNode(at: value.location)
                    }
            )

            // Legend + stats overlay
            VStack {
                Spacer()
                graphLegend
            }

            // Selected node detail
            if let node = selectedNode {
                VStack {
                    nodeDetail(node)
                    Spacer()
                }
            }
        }
        .navigationTitle("Mesh Topology")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Drawing

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        let spacing: CGFloat = 40
        var gridPath = Path()
        for x in stride(from: 0, through: size.width, by: spacing) {
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: 0, through: size.height, by: spacing) {
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(gridPath, with: .color(.secondary.opacity(0.08)), lineWidth: 0.5)
    }

    private func drawEdges(context: GraphicsContext, size: CGSize) {
        for edge in edges {
            guard let from = nodes.first(where: { $0.id == edge.from }),
                  let to = nodes.first(where: { $0.id == edge.to }) else { continue }

            let start = CGPoint(x: from.x * size.width, y: from.y * size.height)
            let end = CGPoint(x: to.x * size.width, y: to.y * size.height)

            var path = Path()
            path.move(to: start)
            path.addLine(to: end)

            let color: Color = edge.isActive ? .green.opacity(0.6) : .secondary.opacity(0.2)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: edge.isActive ? 2 : 1, dash: edge.isActive ? [] : [4, 4]))
        }
    }

    private func drawNodes(context: GraphicsContext, size: CGSize) {
        for node in nodes {
            let center = CGPoint(x: node.x * size.width, y: node.y * size.height)
            let radius = node.type == .local ? 20.0 : (node.type == .interface ? 14.0 : 12.0)

            // Glow effect for active nodes
            if node.isActive {
                let glowRadius = radius + 8 + sin(animationPhase * .pi * 2) * 4
                let glowRect = CGRect(x: center.x - glowRadius, y: center.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)
                context.fill(Path(ellipseIn: glowRect), with: .color(node.color.opacity(0.15)))
            }

            // Node circle
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(node.color))
            context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2)

            // Type icon text inside node
            let typeLabel: String
            switch node.type {
            case .local: typeLabel = "Y"
            case .interface: typeLabel = "I"
            case .peer: typeLabel = "P"
            case .transport: typeLabel = "T"
            }
            let iconText = Text(typeLabel).font(.system(size: radius * 0.7, weight: .bold)).foregroundStyle(.white)
            context.draw(iconText, at: center)

            // Label below node
            let labelText = Text(node.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
            context.draw(labelText, at: CGPoint(x: center.x, y: center.y + radius + 14))
        }
    }

    private func drawPacketParticles(context: GraphicsContext, size: CGSize) {
        for (index, edge) in edges.enumerated() where edge.isActive {
            guard let from = nodes.first(where: { $0.id == edge.from }),
                  let to = nodes.first(where: { $0.id == edge.to }) else { continue }

            let start = CGPoint(x: from.x * size.width, y: from.y * size.height)
            let end = CGPoint(x: to.x * size.width, y: to.y * size.height)

            // Stagger particles so they don't all overlap
            let offset = CGFloat(index) / max(CGFloat(edges.count), 1.0)
            let t = (animationPhase + offset).truncatingRemainder(dividingBy: 1.0)
            let particleX = start.x + (end.x - start.x) * t
            let particleY = start.y + (end.y - start.y) * t

            let particleRect = CGRect(x: particleX - 3, y: particleY - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: particleRect), with: .color(.green))
        }
    }

    // MARK: - Graph Building

    private func buildGraph() {
        var newNodes: [GraphNode] = []
        var newEdges: [GraphEdge] = []

        // Local node at center
        let localNode = GraphNode(
            id: "local",
            label: "You",
            type: .local,
            isActive: true,
            x: 0.5,
            y: 0.45,
            color: .accentColor
        )
        newNodes.append(localNode)

        // Interface nodes in a ring around local
        let interfaceAngles = distributeAngles(count: appState.interfaces.count, startAngle: -.pi / 2)
        for (i, iface) in appState.interfaces.enumerated() {
            let angle = interfaceAngles[i]
            let radius: CGFloat = 0.15
            let node = GraphNode(
                id: "iface-\(iface.id)",
                label: iface.name,
                type: .interface,
                isActive: iface.isOnline,
                x: 0.5 + cos(angle) * radius,
                y: 0.45 + sin(angle) * radius * 1.5,
                color: iface.isOnline ? .green : .gray
            )
            newNodes.append(node)
            newEdges.append(GraphEdge(from: "local", to: node.id, isActive: iface.isOnline))
        }

        // Peer nodes in outer ring
        let peerAngles = distributeAngles(count: appState.knownPeers.count, startAngle: 0)
        for (i, peer) in appState.knownPeers.enumerated() {
            let angle = peerAngles[i]
            // Deterministic offset using first bytes of the hex hash (stable across launches)
            let stableValue = peer.hexHash.prefix(4).unicodeScalars.reduce(0) { acc, c in acc &* 31 &+ Int(c.value) }
            let hashOffset = CGFloat(abs(stableValue) % 256) / 255.0 * 0.06 - 0.03
            let radius: CGFloat = 0.3 + hashOffset
            let node = GraphNode(
                id: "peer-\(peer.hexHash)",
                label: peer.displayName.isEmpty ? peer.shortHash : peer.displayName,
                type: .peer,
                isActive: true,
                x: 0.5 + cos(angle) * radius,
                y: 0.45 + sin(angle) * radius * 1.2,
                color: .orange
            )
            newNodes.append(node)

            // Connect to nearest interface or directly to local
            if let nearestIface = newNodes.filter({ $0.type == .interface && $0.isActive }).first {
                newEdges.append(GraphEdge(from: nearestIface.id, to: node.id, isActive: true))
            } else {
                newEdges.append(GraphEdge(from: "local", to: node.id, isActive: true))
            }
        }

        nodes = newNodes
        edges = newEdges
    }

    private func distributeAngles(count: Int, startAngle: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            startAngle + (2 * .pi / CGFloat(count)) * CGFloat(i)
        }
    }

    private func selectNode(at point: CGPoint) {
        guard canvasSize.width > 0 else { return }
        let normalizedPoint = CGPoint(x: point.x / canvasSize.width, y: point.y / canvasSize.height)

        selectedNode = nodes.first { node in
            let dx = node.x - normalizedPoint.x
            let dy = node.y - normalizedPoint.y
            return sqrt(dx * dx + dy * dy) < 0.05
        }
    }

    // MARK: - Subviews

    private var graphLegend: some View {
        HStack(spacing: 16) {
            legendItem(color: .accentColor, label: "You")
            legendItem(color: .green, label: "Interface")
            legendItem(color: .orange, label: "Peer")
        }
        .font(.caption2)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding()
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func nodeDetail(_ node: GraphNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(node.color).frame(width: 12, height: 12)
                Text(node.label).font(.headline)
                Spacer()
                Button { selectedNode = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            Text(node.type.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
            if node.isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

// MARK: - Graph Models

struct GraphNode: Identifiable {
    let id: String
    let label: String
    let type: NodeType
    let isActive: Bool
    var x: CGFloat
    var y: CGFloat
    let color: Color

    enum NodeType: String {
        case local, interface, peer, transport
    }
}

struct GraphEdge: Identifiable {
    let id = UUID()
    let from: String
    let to: String
    let isActive: Bool
}

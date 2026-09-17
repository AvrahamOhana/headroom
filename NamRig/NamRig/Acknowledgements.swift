//  Acknowledgements.swift
//  Open-source attribution required by the licenses of NamRig's dependencies.
//  MIT (NeuralAmpModelerCore, AudioDSPTools) requires reproducing the copyright
//  + permission notice; Eigen is MPL-2.0. Reachable from Settings → Legal.

import SwiftUI

struct AcknowledgementsView: View {
    private struct Notice: Identifiable {
        let id = UUID()
        let name: String
        let url: String
        let text: String
    }

    private static let mitAtkinson = """
    MIT License

    Copyright (c) 2023 Steven Atkinson

    Permission is hereby granted, free of charge, to any person obtaining a copy \
    of this software and associated documentation files (the "Software"), to deal \
    in the Software without restriction, including without limitation the rights \
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
    copies of the Software, and to permit persons to whom the Software is \
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all \
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
    SOFTWARE.
    """

    private let notices: [Notice] = [
        Notice(name: "NeuralAmpModelerCore",
               url: "https://github.com/sdatkinson/NeuralAmpModelerCore",
               text: mitAtkinson),
        Notice(name: "AudioDSPTools",
               url: "https://github.com/sdatkinson/AudioDSPTools",
               text: mitAtkinson),
        Notice(name: "Eigen",
               url: "https://eigen.tuxfamily.org",
               text: """
               Portions of this software use the Eigen library, licensed under the \
               Mozilla Public License 2.0 (MPL-2.0). Eigen is used unmodified. The \
               full license text is available at:

               https://www.mozilla.org/MPL/2.0/
               """),
    ]

    var body: some View {
        List {
            Section {
                Text("Headroom is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License v3 (or later). Source code: github.com/AvrahamOhana/nam-rig. The bundled \"Bugera V5\" capture is the author's own, licensed CC BY 4.0.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let u = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html") {
                    Link(destination: u) { Label("GNU GPL v3", systemImage: "link").font(.caption) }
                }
            } header: { Text("Headroom") }
            Section {
                Text("Headroom is built with the following open-source software. Their license terms are reproduced below.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(notices) { n in
                Section {
                    if let u = URL(string: n.url) {
                        Link(destination: u) {
                            Label(n.url, systemImage: "link").font(.caption)
                        }
                    }
                    Text(n.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text(n.name)
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .inlineTitle()
    }
}

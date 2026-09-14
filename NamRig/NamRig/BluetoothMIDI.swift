//
//  BluetoothMIDI.swift
//  NamRig — Apple's Bluetooth LE MIDI pairing sheet (CoreAudioKit). Pairs BLE foot controllers
//  (iRig BlueBoard, Wireless MIDI pedals…) — once paired they show up as regular CoreMIDI sources.
//

#if os(iOS)
import SwiftUI
import CoreAudioKit

struct BluetoothMIDIView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: CABTMIDICentralViewController())
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}
#endif

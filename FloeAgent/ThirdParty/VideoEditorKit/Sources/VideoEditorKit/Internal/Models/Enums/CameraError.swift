//
//  CameraError.swift
//  VideoEditorKit
//
//  Created by Didi on 27/03/26.
//

enum CameraError: Error {
    case deniedAuthorization
    case restrictedAuthorization
    case unknowAuthorization
    case cameraUnavalible
    case cannotAddInput
    case createCaptureInput(Error)
    case outputError(Error)
}

#!/usr/bin/env python3
"""
Step 04 of the Sentry Runbook: prove the Tapo C211 actually supports
remote ONVIF pan/tilt before ordering more cameras.

Reads credentials from the environment (source .env first), never
hardcodes them. Prints device info, media profiles, and the PTZ node's
supported spaces -- specifically whether RelativePanTiltTranslationSpace
with TranslationSpaceFov is present -- then attempts a small, brief
ContinuousMove so you can watch the camera physically move.
"""
import os
import sys
import time

from onvif import ONVIFCamera

# Work around a known onvif-zeep / zeep incompatibility: some camera responses
# (Tapo included) contain attributes typed as xsd:anySimpleType, which zeep's
# base SimpleType deliberately leaves unimplemented for subclasses to define.
# Without this patch, GetProfiles() (and similar calls) raise:
#   NotImplementedError: AnySimpleType.pytonvalue() not implemented
from zeep.xsd.types.simple import AnySimpleType
AnySimpleType.pythonvalue = lambda self, value: value

IP = os.environ["CAMERA_IP"]
PORT = int(os.environ.get("CAMERA_ONVIF_PORT", "2020"))
USER = os.environ["CAMERA_RTSP_USER"]
PASS = os.environ["CAMERA_RTSP_PASS"]


def main():
    cam = ONVIFCamera(IP, PORT, USER, PASS)

    print("=== Device info ===")
    devicemgmt = cam.create_devicemgmt_service()
    info = devicemgmt.GetDeviceInformation()
    print(info)

    print("\n=== Media profiles ===")
    media = cam.create_media_service()
    profiles = media.GetProfiles()
    for p in profiles:
        print(f"- token={p.token} name={p.Name}")
        if p.VideoEncoderConfiguration:
            res = p.VideoEncoderConfiguration.Resolution
            print(f"  resolution={res.Width}x{res.Height}")

    if not profiles:
        print("No media profiles returned -- can't continue to PTZ test.")
        sys.exit(1)

    profile_token = profiles[0].token

    print("\n=== PTZ node capabilities ===")
    ptz = cam.create_ptz_service()
    ptz_config = profiles[0].PTZConfiguration
    if ptz_config is None:
        print("This profile has no PTZConfiguration -- camera likely has no ONVIF PTZ at all.")
        sys.exit(1)

    node_token = ptz_config.NodeToken
    node = ptz.GetNode({"NodeToken": node_token})
    print(f"PTZ node: {node.Name} (token={node.token})")

    has_fov_translation = False
    spaces = node.SupportedPTZSpaces
    for space_type in ("ContinuousPanTiltVelocitySpace", "RelativePanTiltTranslationSpace",
                        "AbsolutePanTiltPositionSpace"):
        entries = getattr(spaces, space_type, None) or []
        print(f"\n{space_type}:")
        for e in entries:
            print(f"  URI={e.URI}")
            if space_type == "RelativePanTiltTranslationSpace" and "TranslationSpaceFov" in e.URI:
                has_fov_translation = True

    print(f"\nHas RelativePanTiltTranslationSpace w/ TranslationSpaceFov: {has_fov_translation}")

    print("\n=== Attempting ContinuousMove (watch the camera now) ===")
    request = ptz.create_type("ContinuousMove")
    request.ProfileToken = profile_token
    request.Velocity = {"PanTilt": {"x": -0.5, "y": 0.0}}
    ptz.ContinuousMove(request)
    print("Moving left for 2 seconds...")
    time.sleep(2)

    stop_request = ptz.create_type("Stop")
    stop_request.ProfileToken = profile_token
    stop_request.PanTilt = True
    ptz.Stop(stop_request)
    print("Stop sent. Did the camera physically move?")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from tkinter import BOTH, BOTTOM, DISABLED, LEFT, NORMAL, X, Button, Frame, Label, PhotoImage, StringVar, Tk


@dataclass
class CameraConfig:
    device: str = "/dev/video0"
    out_root: str = "~/recordings/tennis"
    video_size: str = "3840x2160"
    framerate: int = 30
    input_format: str = "mjpeg"
    exposure_absolute: int = 200
    white_balance_temperature: int = 4600
    brightness: int = -5
    contrast: int = 1
    saturation: int = 64
    gamma: int = 100
    gain: int = 32
    power_line_frequency: int = 1
    sharpness: int = 1
    backlight_compensation: int = 0
    focus_automatic_continuous: int = 0
    preview_width: int = 960
    preview_fps: int = 10
    sample_fps: float | None = None

    @property
    def controls(self) -> list[str]:
        return [
            "auto_exposure=1",
            f"exposure_time_absolute={self.exposure_absolute}",
            "white_balance_automatic=0",
            f"white_balance_temperature={self.white_balance_temperature}",
            f"brightness={self.brightness}",
            f"contrast={self.contrast}",
            f"saturation={self.saturation}",
            f"gamma={self.gamma}",
            f"gain={self.gain}",
            f"power_line_frequency={self.power_line_frequency}",
            f"sharpness={self.sharpness}",
            f"backlight_compensation={self.backlight_compensation}",
            f"focus_automatic_continuous={self.focus_automatic_continuous}",
        ]


class TennisRecorderGui:
    def __init__(self, config: CameraConfig) -> None:
        self.config = config
        self.root = Tk()
        self.root.title("Tennis Camera Recorder")
        self.root.protocol("WM_DELETE_WINDOW", self.close)

        self.status = StringVar(value="Starting preview...")
        self.video_label = Label(self.root, bg="black")
        self.video_label.pack(fill=BOTH, expand=True)

        controls = Frame(self.root)
        controls.pack(side=BOTTOM, fill=X)
        self.record_button = Button(controls, text="Start Recording", command=self.start_recording)
        self.record_button.pack(side=LEFT, padx=8, pady=8)
        self.stop_button = Button(controls, text="Stop Recording", state=DISABLED, command=self.stop_recording)
        self.stop_button.pack(side=LEFT, padx=8, pady=8)
        Label(controls, textvariable=self.status).pack(side=LEFT, padx=8)

        self.preview_process: subprocess.Popen[bytes] | None = None
        self.record_process: subprocess.Popen[bytes] | None = None
        self.preview_thread: threading.Thread | None = None
        self.last_image: PhotoImage | None = None
        self.closing = False
        self.recording_started_at: float | None = None
        self.current_output: Path | None = None

        self.configure_camera()
        self.start_preview()
        self.tick()

    def run(self) -> None:
        self.root.mainloop()

    def configure_camera(self) -> None:
        width, height = self.config.video_size.split("x", 1)
        subprocess.run(
            [
                "v4l2-ctl",
                "-d",
                self.config.device,
                f"--set-fmt-video=width={width},height={height},pixelformat=MJPG",
                f"--set-parm={self.config.framerate}",
            ],
            check=True,
        )
        for control in self.config.controls:
            result = subprocess.run(
                ["v4l2-ctl", "-d", self.config.device, f"--set-ctrl={control}"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if result.returncode != 0:
                print(f"Warning: failed to set {control}: {result.stderr.strip()}", file=sys.stderr)

    def start_preview(self) -> None:
        if self.preview_process is not None:
            return
        command = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "v4l2",
            "-input_format",
            self.config.input_format,
            "-video_size",
            self.config.video_size,
            "-framerate",
            str(self.config.framerate),
            "-i",
            self.config.device,
            "-vf",
            f"fps={self.config.preview_fps},scale={self.config.preview_width}:-1",
            "-f",
            "image2pipe",
            "-vcodec",
            "ppm",
            "-",
        ]
        self.preview_process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.preview_thread = threading.Thread(target=self.read_preview_frames, daemon=True)
        self.preview_thread.start()
        self.status.set("Previewing")

    def stop_preview(self) -> None:
        process = self.preview_process
        self.preview_process = None
        if process is not None:
            terminate_process(process)

    def read_preview_frames(self) -> None:
        process = self.preview_process
        if process is None or process.stdout is None:
            return
        while not self.closing and self.preview_process is process:
            frame = read_ppm(process.stdout)
            if frame is None:
                break
            self.root.after(0, self.show_frame, frame)
        if not self.closing and self.preview_process is process:
            self.root.after(0, self.preview_failed)

    def show_frame(self, frame: bytes) -> None:
        if self.closing:
            return
        image = PhotoImage(data=frame, format="PPM")
        self.last_image = image
        self.video_label.configure(image=image)

    def preview_failed(self) -> None:
        if self.record_process is None:
            self.status.set("Preview stopped. Is another app using the camera?")

    def start_recording(self) -> None:
        if self.record_process is not None:
            return
        self.record_button.configure(state=DISABLED)
        self.status.set("Freezing preview and starting recording...")
        self.stop_preview()
        self.configure_camera()

        timestamp = time.strftime("%Y%m%d_%H%M%S")
        out_root = Path(os.path.expanduser(self.config.out_root))
        out_dir = out_root / timestamp
        out_dir.mkdir(parents=True, exist_ok=True)
        output = out_dir / f"{timestamp}_video0.mkv"
        command = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "info",
            "-n",
            "-f",
            "v4l2",
            "-input_format",
            self.config.input_format,
            "-video_size",
            self.config.video_size,
            "-framerate",
            str(self.config.framerate),
            "-i",
            self.config.device,
        ]
        if self.config.sample_fps is not None:
            command.extend(
                [
                    "-vf",
                    f"fps={format_number(self.config.sample_fps)}",
                    "-map",
                    "0:v:0",
                    "-c:v",
                    "mjpeg",
                    "-q:v",
                    "3",
                    "-an",
                    "-f",
                    "matroska",
                    str(output),
                ]
            )
        else:
            command.extend(["-map", "0:v:0", "-c:v", "copy", "-an", "-f", "matroska", str(output)])
        self.record_process = subprocess.Popen(command)
        self.recording_started_at = time.monotonic()
        self.current_output = output
        self.stop_button.configure(state=NORMAL)
        if self.config.sample_fps is None:
            self.status.set(f"Recording: {output}")
        else:
            self.status.set(f"Recording {format_number(self.config.sample_fps)} fps: {output}")

    def stop_recording(self) -> None:
        process = self.record_process
        if process is not None:
            terminate_process(process)
        self.record_process = None
        self.recording_started_at = None
        self.stop_button.configure(state=DISABLED)
        self.record_button.configure(state=NORMAL)
        if self.current_output is not None:
            self.status.set(f"Saved: {self.current_output}")
        self.current_output = None
        self.configure_camera()
        self.start_preview()

    def tick(self) -> None:
        if self.record_process is not None and self.recording_started_at is not None and self.current_output is not None:
            elapsed = int(time.monotonic() - self.recording_started_at)
            if self.config.sample_fps is None:
                self.status.set(f"Recording {elapsed}s: {self.current_output}")
            else:
                self.status.set(f"Recording {elapsed}s at {format_number(self.config.sample_fps)} fps: {self.current_output}")
            if self.record_process.poll() is not None:
                self.stop_recording()
        self.root.after(1000, self.tick)

    def close(self) -> None:
        self.closing = True
        self.stop_preview()
        if self.record_process is not None:
            terminate_process(self.record_process)
        self.root.destroy()


def terminate_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGINT)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def read_ppm(stream) -> bytes | None:
    magic = stream.readline()
    if not magic:
        return None
    if magic != b"P6\n":
        return None
    header = bytearray(magic)
    tokens: list[bytes] = []
    while len(tokens) < 3:
        line = stream.readline()
        if not line:
            return None
        header.extend(line)
        if line.startswith(b"#"):
            continue
        tokens.extend(line.split())
    width = int(tokens[0])
    height = int(tokens[1])
    max_value = int(tokens[2])
    if max_value != 255:
        return None
    payload_size = width * height * 3
    payload = stream.read(payload_size)
    if len(payload) != payload_size:
        return None
    return bytes(header) + payload


def format_number(value: float) -> str:
    if value.is_integer():
        return str(int(value))
    return str(value)


def parse_args() -> CameraConfig:
    parser = argparse.ArgumentParser(description="GUI recorder for the local tennis camera.")
    parser.add_argument("--device", default="/dev/video0")
    parser.add_argument("--out-root", default="~/recordings/tennis")
    parser.add_argument("--preview-width", type=int, default=960)
    parser.add_argument("--preview-fps", type=int, default=10)
    parser.add_argument("--sample-fps", type=float, default=None, help="Keep only this many frames per second while recording.")
    parser.add_argument("--exposure", type=int, default=200)
    parser.add_argument("--wb", type=int, default=4600)
    args = parser.parse_args()
    return CameraConfig(
        device=args.device,
        out_root=args.out_root,
        exposure_absolute=args.exposure,
        white_balance_temperature=args.wb,
        preview_width=args.preview_width,
        preview_fps=args.preview_fps,
        sample_fps=args.sample_fps,
    )


def main() -> int:
    try:
        TennisRecorderGui(parse_args()).run()
    except subprocess.CalledProcessError as exc:
        print(f"Command failed: {' '.join(exc.cmd)}", file=sys.stderr)
        return exc.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

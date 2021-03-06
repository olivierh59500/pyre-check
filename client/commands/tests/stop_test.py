# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import os
import unittest
from io import StringIO
from typing import List, Optional
from unittest.mock import MagicMock, Mock, call, patch

from ... import commands
from ...analysis_directory import AnalysisDirectory
from .command_test import mock_arguments, mock_configuration


def _mark_processes_as_completed(process_id: int, signal: int) -> None:
    if signal == 0:
        raise ProcessLookupError()
    else:
        return


@patch.object(os, "kill", side_effect=_mark_processes_as_completed)
@patch.object(commands.stop.WatchmanSubscriber, "stop_subscriber")
@patch.object(commands.stop, "open", side_effect=lambda filename: StringIO("42"))
@patch.object(commands.Kill, "_run")
@patch.object(commands.Command, "_state")
class StopTest(unittest.TestCase):
    def setUp(self) -> None:
        self.original_directory = "/original/directory"
        self.arguments = mock_arguments()
        self.arguments.terminal = False
        self.configuration = mock_configuration()
        self.analysis_directory = AnalysisDirectory(".")

    def test_stop_running_server(
        self,
        commands_Command_state: MagicMock,
        kill_command_run: MagicMock,
        file_open: MagicMock,
        stop_subscriber: MagicMock,
        os_kill: MagicMock,
    ) -> None:
        commands_Command_state.return_value = commands.command.State.RUNNING
        with patch.object(commands.Command, "_call_client") as call_client:
            commands.Stop(
                self.arguments,
                self.original_directory,
                self.configuration,
                self.analysis_directory,
            ).run()
            call_client.assert_called_once_with(command=commands.Stop.NAME)
            kill_command_run.assert_not_called()
            os_kill.assert_called_once_with(42, 0)
            stop_subscriber.assert_has_calls(
                [
                    call(".pyre/file_monitor", "file_monitor"),
                    call(".pyre/configuration_monitor", "configuration_monitor"),
                ]
            )

    def test_stop_dead_server(
        self,
        commands_Command_state: MagicMock,
        kill_command_run: MagicMock,
        file_open: MagicMock,
        stop_subscriber: MagicMock,
        os_kill: MagicMock,
    ) -> None:
        commands_Command_state.return_value = commands.command.State.DEAD
        with patch.object(commands.Command, "_call_client") as call_client:
            commands.Stop(
                self.arguments,
                self.original_directory,
                self.configuration,
                self.analysis_directory,
            ).run()
            call_client.assert_not_called()
            kill_command_run.assert_called_once()
            os_kill.assert_not_called()
            self.assertEqual(stop_subscriber.call_count, 2)

    def test_stop_running_server__stop_fails(
        self,
        commands_Command_state: MagicMock,
        kill_command_run: MagicMock,
        file_open: MagicMock,
        stop_subscriber: MagicMock,
        os_kill: MagicMock,
    ) -> None:
        commands_Command_state.return_value = commands.command.State.RUNNING
        with patch.object(commands.Command, "_call_client") as call_client:

            def fail_on_stop(command: str, flags: Optional[List[str]] = None) -> Mock:
                flags = flags or []
                if command == commands.Stop.NAME:
                    raise commands.ClientException
                return Mock()

            call_client.side_effect = fail_on_stop
            commands.Stop(
                self.arguments,
                self.original_directory,
                self.configuration,
                self.analysis_directory,
            ).run()
            call_client.assert_has_calls([call(command=commands.Stop.NAME)])
            kill_command_run.assert_called_once()
            os_kill.assert_not_called()
            self.assertEqual(stop_subscriber.call_count, 2)

    def test_stop_ignores_flags(
        self,
        commands_Command_state: MagicMock,
        kill_command_run: MagicMock,
        file_open: MagicMock,
        stop_subscriber: MagicMock,
        os_kill: MagicMock,
    ) -> None:
        self.arguments.debug = True
        flags = commands.Stop(
            self.arguments,
            self.original_directory,
            self.configuration,
            self.analysis_directory,
        )._flags()
        self.assertEqual(flags, ["-log-directory", ".pyre"])

    def test_stop_no_pid(
        self,
        commands_Command_state: MagicMock,
        kill_command_run: MagicMock,
        file_open: MagicMock,
        stop_subscriber: MagicMock,
        os_kill: MagicMock,
    ) -> None:
        with patch.object(commands.Stop, "_pid_file", return_value=None), patch.object(
            commands.Command, "_call_client"
        ) as call_client:
            commands.Stop(
                self.arguments,
                self.original_directory,
                self.configuration,
                self.analysis_directory,
            ).run()
            call_client.assert_has_calls([call(command=commands.Stop.NAME)])
            kill_command_run.assert_called_once()

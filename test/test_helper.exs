# The serial line tests join two pseudo-terminals with socat, and run where it's installed.
#
# The interop tests run against pymodbus in a separate process, and need PYMODBUS_PYTHON to point to
# a Python with pymodbus installed:
#
#     python3 -m venv ~/.venvs/pymodbus && ~/.venvs/pymodbus/bin/pip install pymodbus
#     PYMODBUS_PYTHON=~/.venvs/pymodbus/bin/python mix test
exclude = if System.find_executable("socat"), do: [], else: [:socat]
exclude = if System.get_env("PYMODBUS_PYTHON"), do: exclude, else: [:interop | exclude]
ExUnit.start(exclude: exclude)

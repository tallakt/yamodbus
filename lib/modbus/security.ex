defmodule Modbus.Security do
  @moduledoc false
  # Modbus/TCP Security (MB-TCP-Security v36): TLS 1.2 or later with certificates both ways, and the
  # client's role carried in its certificate.

  # The role extension, an ASN.1 UTF8String (R-21, R-22).
  @role {1, 3, 6, 1, 4, 1, 50316, 802, 1}

  def role_oid, do: @role

  # TLS 1.2 or later, never down to 1.1 (R-01, R-34); no SHA-1 MACs or PRFs (R-51, R-54); the
  # server's certificate checked. OTP's ssl would log every failed handshake; the reason is in the
  # error instead.
  def client_options(ssl) do
    Keyword.merge(
      [verify: :verify_peer, versions: versions(), ciphers: ciphers(), log_level: :none],
      ssl
    )
  end

  # As for the client, and the server asks for the client's certificate and refuses a client that
  # doesn't send one (R-07, R-10, R-44).
  def server_options(ssl) do
    Keyword.merge(
      [
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        versions: versions(),
        ciphers: ciphers(),
        reuse_sessions: true,
        log_level: :none
      ],
      ssl
    )
  end

  defp versions, do: [:"tlsv1.3", :"tlsv1.2"]

  defp ciphers do
    tls12 =
      :ssl.cipher_suites(:default, :"tlsv1.2")
      |> :ssl.filter_cipher_suites(mac: &(&1 not in [:sha, :md5]), prf: &(&1 != :sha))

    :ssl.cipher_suites(:default, :"tlsv1.3") ++ tls12
  end

  # The role in the client's certificate on a TLS socket, or nil if it has none (R-23), or one
  # that isn't a UTF8String.
  def role(socket) do
    with {:ok, der} <- :ssl.peercert(socket),
         {:OTPCertificate, tbs, _, _} <- decode(der),
         extensions when is_list(extensions) <- elem(tbs, 10),
         {:Extension, @role, _critical, value} <- List.keyfind(extensions, @role, 1) do
      role_value(value)
    else
      _ -> nil
    end
  end

  defp decode(der) do
    :public_key.pkix_decode_cert(der, :otp)
  rescue
    _error -> nil
  end

  @doc false
  # An extension OTP doesn't know is left as its DER: here a UTF8String, tag 12, its length in one
  # byte or, from 128, in one or two after 0x81 or 0x82. Anything else, whole or not, is nil.
  def role_value(<<12, length, string::binary>>)
      when length < 128 and byte_size(string) == length,
      do: utf8(string)

  def role_value(<<12, 0x81, length, string::binary>>)
      when length >= 128 and byte_size(string) == length,
      do: utf8(string)

  def role_value(<<12, 0x82, length::16, string::binary>>)
      when length >= 256 and byte_size(string) == length,
      do: utf8(string)

  def role_value(_value), do: nil

  defp utf8(string), do: if(String.valid?(string), do: string)
end

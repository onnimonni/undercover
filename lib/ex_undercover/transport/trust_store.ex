defmodule ExUndercover.Transport.TrustStore do
  @moduledoc """
  Helpers for installing and applying a custom CA bundle.
  """

  @bundle_name "custom_roots.pem"

  @spec install!(binary()) :: binary()
  def install!(source_path) when is_binary(source_path) do
    target_path = installed_path()
    File.mkdir_p!(Path.dirname(target_path))
    File.cp!(source_path, target_path)
    target_path
  end

  @spec installed_path() :: binary()
  def installed_path do
    Application.app_dir(:ex_undercover, "priv/certs/#{@bundle_name}")
  end

  @spec apply_default_bundle(map()) :: map()
  def apply_default_bundle(metadata) when is_map(metadata) do
    cond do
      Map.has_key?(metadata, :ca_cert_file) or Map.has_key?(metadata, "ca_cert_file") ->
        metadata

      File.exists?(installed_path()) ->
        Map.put(metadata, "ca_cert_file", installed_path())

      true ->
        metadata
    end
  end
end

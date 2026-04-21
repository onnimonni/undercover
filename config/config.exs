import Config

config :ex_undercover,
  default_browser_profile: :chrome_latest,
  solver: :chrome,
  profile_aliases: %{
    chrome_latest: :chrome_147
  }

config :rustler,
  otp_app: :ex_undercover,
  crate: "ex_undercover_nif"

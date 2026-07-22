import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :earss, Earss.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  secret =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing"

  config :earss, :api,
    enabled: System.get_env("API_ENABLED", "true") in ~w(true 1),
    port: String.to_integer(System.get_env("PORT") || "4000"),
    secret_key_base: secret,
    token_max_age_secs:
      String.to_integer(System.get_env("TOKEN_MAX_AGE_SECS") || "#{60 * 60 * 24 * 30}")
end

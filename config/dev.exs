import Config

config :earss, Earss.Repo,
  database: "earss_dev",
  username: "postgres",
  password: "",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :logger, level: :debug

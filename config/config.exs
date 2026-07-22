import Config

config :earss,
  ecto_repos: [Earss.Repo]

# 刷新间隔全局默认（分钟）— 与 feeds 表默认值一致（D7）
config :earss, :refresh,
  min_interval: 15,
  max_interval: 10_080,
  default_interval: 30

# 数据保留（天）— 见 docs/data_lifecycle.md
config :earss, :retention,
  read_state_days: 90,
  entry_days: 180,
  unsubscribed_feed_days: 30

import_config "#{config_env()}.exs"

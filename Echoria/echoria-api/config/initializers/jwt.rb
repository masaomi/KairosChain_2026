# JWT Configuration for Echoria API

JWT_CONFIG = {
  algorithm: "HS256",
  secret: Rails.application.config.x.jwt.secret,
  exp_time: 7.days.to_i
}.freeze

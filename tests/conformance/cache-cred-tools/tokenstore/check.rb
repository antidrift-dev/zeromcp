tool description: "Return the current token from credentials",
     input: {}

execute do |args, ctx|
  creds = ctx.credentials
  {
    "token" => creds.is_a?(Hash) ? creds["token"] : nil,
  }
end

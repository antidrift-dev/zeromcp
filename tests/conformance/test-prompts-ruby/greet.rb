prompt description: "Greeting prompt",
  arguments: {
    name: "string",
    tone: { type: "string", optional: true, description: "formal or casual" }
  }

render do |args|
  name = args["name"] || "world"
  tone = args["tone"] || "casual"
  [{ "role" => "user", "content" => { "type" => "text", "text" => "Greet #{name} in a #{tone} tone" } }]
end

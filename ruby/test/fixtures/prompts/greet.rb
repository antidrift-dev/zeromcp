prompt description: "Generate a greeting",
       arguments: {
         name: "string",
         style: { type: "string", description: "Greeting style", optional: true }
       }

render do |args|
  style = args['style'] || 'friendly'
  [
    { "role" => "user", "content" => { "type" => "text", "text" => "Say hello to #{args['name']} in a #{style} way." } }
  ]
end

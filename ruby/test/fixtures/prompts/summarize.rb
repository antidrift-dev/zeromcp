prompt description: "Summarize a document",
       arguments: { text: "string" }

render do |args|
  [
    { "role" => "user", "content" => { "type" => "text", "text" => "Summarize the following:\n#{args['text']}" } }
  ]
end

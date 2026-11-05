import "jsr:@supabase/functions-js/edge-runtime.d.ts";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey"
};
function buildAdaptiveCard(payload) {
  const keyRows = payload.keys.map((k)=>({
      type: "ColumnSet",
      columns: [
        {
          type: "Column",
          width: "stretch",
          items: [
            {
              type: "TextBlock",
              text: `\`${k.key}\``,
              wrap: true,
              size: "Small",
              font: "Monospace"
            }
          ]
        },
        {
          type: "Column",
          width: "stretch",
          items: [
            {
              type: "TextBlock",
              text: k.fallback,
              wrap: true,
              size: "Small"
            }
          ]
        }
      ]
    }));
  return {
    type: "message",
    attachments: [
      {
        contentType: "application/vnd.microsoft.card.adaptive",
        content: {
          $schema: "http://adaptivecards.io/schemas/adaptive-card.json",
          type: "AdaptiveCard",
          version: "1.4",
          body: [
            {
              type: "TextBlock",
              text: "New Translation Keys Added",
              weight: "Bolder",
              size: "Medium",
              color: "Accent"
            },
            {
              type: "TextBlock",
              text: payload.description,
              wrap: true,
              spacing: "Small"
            },
            {
              type: "FactSet",
              facts: [
                {
                  title: "Namespace",
                  value: payload.namespace
                },
                {
                  title: "Keys count",
                  value: String(payload.keys.length)
                }
              ]
            },
            {
              type: "TextBlock",
              text: "Keys & English Fallback",
              weight: "Bolder",
              size: "Small",
              spacing: "Medium"
            },
            ...keyRows,
            {
              type: "TextBlock",
              text: "Please add FR and AR translations in the backoffice.",
              wrap: true,
              spacing: "Large",
              weight: "Bolder",
              color: "Warning"
            }
          ]
        }
      }
    ]
  };
}
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 200,
      headers: corsHeaders
    });
  }
  try {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({
        error: "Method not allowed"
      }), {
        status: 405,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    const payload = await req.json();
    if (!payload.keys || payload.keys.length === 0) {
      return new Response(JSON.stringify({
        error: "No keys provided"
      }), {
        status: 400,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    const webhookUrl = Deno.env.get("TEAMS_WEBHOOK_URL");
    if (!webhookUrl) {
      return new Response(JSON.stringify({
        error: "TEAMS_WEBHOOK_URL not configured"
      }), {
        status: 500,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    const card = buildAdaptiveCard(payload);
    const teamsResponse = await fetch(webhookUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(card)
    });
    if (!teamsResponse.ok) {
      const errorText = await teamsResponse.text();
      return new Response(JSON.stringify({
        error: "Failed to post to Teams",
        details: errorText
      }), {
        status: 502,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json"
        }
      });
    }
    return new Response(JSON.stringify({
      success: true,
      keysNotified: payload.keys.length
    }), {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  } catch (err) {
    return new Response(JSON.stringify({
      error: "Internal error",
      details: String(err)
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json"
      }
    });
  }
});

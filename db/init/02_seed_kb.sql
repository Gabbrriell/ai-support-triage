-- Starter KB so search_kb() has something to hit on day one. Add more as you write eval tickets.
INSERT INTO kb_articles (slug, title, category, tags, body) VALUES
('meta-spend-mismatch',
 'Meta Ads spend does not match Ads Manager',
 'data_discrepancy', ARRAY['meta','facebook','spend','ads manager','discrepancy'],
 'Most common causes: (1) Timezone. Ads Manager reports in the ad account timezone, the warehouse may store UTC. Compare with the same timezone. (2) Attribution window. Ads Manager defaults to 7-day click / 1-day view; check the connector setting matches. (3) Data freshness. Meta revises spend for up to 28 days; recent days can shift after the last sync. (4) Currency. Multi-currency accounts may be converted at load time. Ask the customer for: ad account ID, date range, the exact Ads Manager number and the number they see on our side.'),

('google-ads-token-expired',
 'Google Ads connector: token expired or revoked',
 'connector_auth', ARRAY['google ads','oauth','token','expired','invalid_grant','reauthorize'],
 'Error invalid_grant or "token has been expired or revoked" means the OAuth refresh token is no longer valid. Common triggers: the user who connected the account changed their Google password, left the company, or removed app access; Google Cloud projects in testing mode expire tokens after 7 days. Fix: reconnect the data source with a user who has at least read access to the Google Ads account, then re-run the failed extractions for the missed dates.'),

('ga4-missing-conversions',
 'GA4 conversions missing or lower than expected',
 'data_discrepancy', ARRAY['ga4','google analytics','conversions','key events','missing'],
 'Check: (1) Event was marked as a key event (conversion) only after a certain date; GA4 does not backfill. (2) Data thresholding applies when Google Signals is on, rows can be hidden in the API. (3) GA4 data takes 24-48h to finalise; very recent days are incomplete. (4) The connector pulls a specific property ID; confirm it is the right property, not a test or roll-up property. Ask for property ID, event name, date range and a screenshot of the GA4 report.'),

('api-rate-limit-429',
 'Extraction failing with 429 / rate limit errors',
 'api_error', ARRAY['429','rate limit','quota','api','extraction failed'],
 'A 429 means the source platform throttled our requests. Usually temporary; the extraction retries with backoff. If it keeps failing: large historical backfills should be split into smaller date ranges, and several connectors sharing one developer token share one quota. Collect: data source, time of the failure, error text from the extraction log.'),

('api-schema-change',
 'Extraction errors after a platform API version change',
 'api_error', ARRAY['api version','deprecated','field not found','schema','400'],
 'Errors like "unrecognized field" or 400 Bad Request right after a platform release usually mean a field was deprecated in a new API version. Check the platform changelog, then escalate to the connectors team with the data source, extraction ID and the exact field name. Do not tell the customer a fix date until engineering confirms.'),

('billing-invoice-question',
 'Invoice questions and plan changes',
 'billing', ARRAY['invoice','billing','plan','upgrade','payment','charge'],
 'Support does not change plans or issue refunds. Confirm the account name and invoice number, then route to the account manager / billing team. For failed payments, ask the customer to update the card in the billing portal and confirm once done.');

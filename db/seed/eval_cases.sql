-- Labelled eval set: realistic marketing-data support tickets.
-- Load once:  Get-Content db\seed\eval_cases.sql | docker compose exec -T postgres psql -U postgres -d support
-- Some cases are deliberately tricky (notes column says why).

INSERT INTO eval_cases (subject, body, expected_category, expected_priority, notes) VALUES

-- data_discrepancy -----------------------------------------------------------
('Meta spend lower than Ads Manager',
 'Our dashboard shows 12,340 EUR Meta spend for September but Ads Manager says 12,910 EUR. Ad account act_88213. Can you check?',
 'data_discrepancy','normal', NULL),

('Yesterday''s Facebook numbers changed',
 'The Facebook spend for Oct 3 was 1,820 yesterday and today it shows 1,905. Why are you changing historical data?',
 'data_discrepancy','low', 'Meta restating recent days; expected behaviour, low priority'),

('GA4 conversions missing for purchase event',
 'GA4 shows 412 purchases last week but your report only has 290. Property 3451209. The purchase event is a key event.',
 'data_discrepancy','normal', NULL),

('Google Ads clicks don''t match',
 'Clicks for campaign Brand_UK are 5% higher in Google Ads UI than in our Looker dashboard fed by you. Same date range, same account.',
 'data_discrepancy','normal', NULL),

('TikTok data stopped updating',
 'TikTok Ads data in the warehouse ends on Oct 9. Nothing since then, no errors that I can see.',
 'data_discrepancy','high', 'Could look like api_error, but customer reports missing data with no error'),

('Revenue doubled in report',
 'Our blended ROAS report shows revenue exactly 2x what Shopify shows for last month. Looks like rows are duplicated somewhere.',
 'data_discrepancy','high', NULL),

('Timezone question on daily spend',
 'Is the daily spend in the warehouse in UTC or in the ad account timezone? Our totals by day don''t line up with Ads Manager.',
 'data_discrepancy','low', 'Phrased as question, still a discrepancy'),

('CPM looks wrong for all LinkedIn campaigns',
 'All LinkedIn campaigns show CPM around 3x what LinkedIn Campaign Manager shows. This is going into the client report on Friday.',
 'data_discrepancy','high', NULL),

('Board report numbers are wrong NOW',
 'Our CMO is presenting in one hour and total paid media spend across Meta, Google and TikTok is off by 40k vs the platforms. Need help immediately.',
 'data_discrepancy','urgent', NULL),

('Missing campaign in dataset',
 'A new Google Ads campaign launched Oct 1 (Fall_Promo_DE) does not appear in the dataset, other campaigns are there.',
 'data_discrepancy','normal', NULL),

-- connector_auth -------------------------------------------------------------
('Google Ads connector says invalid_grant',
 'Getting invalid_grant on the Google Ads source since Monday. Nothing changed on our side as far as I know.',
 'connector_auth','high', NULL),

('Reconnect needed after employee left',
 'The person who connected our Meta accounts left the company and now the connection shows as disconnected. How do we move it to another user?',
 'connector_auth','high', NULL),

('Permission error on GA4 property',
 'Extraction for GA4 property 2871100 fails with "User does not have sufficient permissions for this property".',
 'connector_auth','normal', 'Has error text, but cause is permissions, not API'),

('How to add a second Google Ads MCC',
 'We want to connect another MCC to our workspace. Do I need admin access on the MCC or is standard enough?',
 'connector_auth','low', NULL),

('All connectors disconnected after SSO change',
 'We switched our company to Okta SSO last night and every single data source (40+ accounts) now shows authentication failed. Nothing is loading.',
 'connector_auth','urgent', NULL),

('LinkedIn token expires every 60 days',
 'We have to reauthorize LinkedIn every two months, it''s annoying. Is there a way to avoid this?',
 'connector_auth','low', NULL),

('TikTok connection asks for login again',
 'TikTok source shows "authorization expired, please reconnect". Can I just click reconnect or will I lose history?',
 'connector_auth','normal', NULL),

-- api_error ------------------------------------------------------------------
('Extraction failing with 429',
 'Our Google Ads backfill for 2 years of data keeps failing with 429 Too Many Requests.',
 'api_error','normal', NULL),

('Field not found error after Meta update',
 'Meta extraction errors with "(#100) Tried accessing nonexisting field (video_avg_percent_watched_actions)" since this morning.',
 'api_error','high', NULL),

('Timeouts on large GA4 report',
 'The GA4 extraction with 9 dimensions times out every night. Smaller reports work fine.',
 'api_error','normal', NULL),

('500 errors from your API',
 'Our scripts calling your reporting API get HTTP 500 on about 30% of requests since 10:00 UTC.',
 'api_error','high', NULL),

('All extractions failing platform-wide',
 'Every extraction in our workspace has failed since 06:00, across Meta, Google Ads, Amazon Ads and Bing. Status page says operational.',
 'api_error','urgent', NULL),

('Schema change broke our dbt models',
 'A column was renamed in the Google Ads table (cost_micros to cost) and our downstream dbt models fail now. Was this announced?',
 'api_error','high', 'Ambiguous with data_discrepancy; root cause is a schema change'),

('Bing Ads extraction error code 105',
 'Microsoft Advertising source fails with error code 105 InvalidCredentials, but the login works fine in the Bing UI.',
 'connector_auth','normal', 'Tricky: looks like api_error but it is an auth problem'),

-- billing --------------------------------------------------------------------
('Invoice has wrong company name',
 'Our October invoice is addressed to our old company name. Can you reissue it?',
 'billing','low', NULL),

('Charged twice this month',
 'We see two charges of 4,500 USD on our card for October. Please refund one.',
 'billing','high', NULL),

('Upgrade to more data sources',
 'We are hitting the data source limit on our plan. What does it cost to add 20 more sources?',
 'billing','normal', NULL),

('Payment failed, will we lose access?',
 'Our card expired and the payment failed. Will extractions stop? We updated the card now.',
 'billing','normal', NULL),

('Need a W-9 and VAT number',
 'Procurement needs your W-9 and EU VAT number to process the renewal.',
 'billing','low', NULL),

-- other ----------------------------------------------------------------------
('Feature request: Pinterest Ads connector',
 'Do you plan to add Pinterest Ads? We''d use it for 3 clients.',
 'other','low', NULL),

('How do I share a dashboard with a client',
 'What''s the best way to give a client view-only access to one dashboard?',
 'other','low', NULL),

('Thank you!',
 'Just wanted to say the fix from yesterday worked, data looks right now. Thanks Nino!',
 'other','low', NULL),

('Training session for new team',
 'We have 5 new analysts joining. Can we book an onboarding session next week?',
 'other','low', NULL),

('GDPR data deletion request',
 'Please confirm how we can delete all data related to one of our former clients from your platform, per GDPR.',
 'other','normal', NULL),

-- deliberately vague / multi-issue -------------------------------------------
('Something is off',
 'Numbers look weird this week. Can someone take a look?',
 'data_discrepancy','normal', 'Vague: model should give low confidence'),

('Disconnected AND invoice question',
 'Our Google Ads connector shows disconnected again. Also, why did our invoice go up this month?',
 'connector_auth','high', 'Two issues: the blocking one (auth) should win');

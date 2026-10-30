-- Controlled industry taxonomy and the first published profile questionnaire definition.
-- Question option codes are stable matching features; labels are presentation text for locale en.
INSERT INTO core.sector(sector_code, parent_sector_code, name, status, sort_order) VALUES
    ('TECHNOLOGY',NULL,'Technology, Software & AI','ACTIVE',10),
    ('FINANCIAL_SERVICES',NULL,'Financial Services, Fintech & Insurance','ACTIVE',20),
    ('HEALTHCARE',NULL,'Healthcare & Life Sciences','ACTIVE',30),
    ('EDUCATION',NULL,'Education & Training','ACTIVE',40),
    ('GOVERNMENT',NULL,'Government & Public Sector','ACTIVE',50),
    ('MANUFACTURING',NULL,'Manufacturing & Industrial','ACTIVE',60),
    ('RETAIL',NULL,'Retail, Consumer Goods & E-commerce','ACTIVE',70),
    ('TELECOMMUNICATIONS',NULL,'Telecommunications','ACTIVE',80),
    ('MEDIA',NULL,'Media, Marketing & Creative','ACTIVE',90),
    ('ENERGY',NULL,'Energy, Utilities & Climate','ACTIVE',100),
    ('CONSTRUCTION',NULL,'Construction, Real Estate & Infrastructure','ACTIVE',110),
    ('LOGISTICS',NULL,'Logistics, Supply Chain & Mobility','ACTIVE',120),
    ('PROFESSIONAL_SERVICES',NULL,'Professional & Business Services','ACTIVE',130),
    ('AGRICULTURE',NULL,'Agriculture & Food','ACTIVE',140),
    ('TRAVEL',NULL,'Travel, Hospitality & Events','ACTIVE',150),
    ('NONPROFIT',NULL,'Nonprofit & Social Impact','ACTIVE',160),
    ('OTHER',NULL,'Other / Not listed','ACTIVE',999)
ON CONFLICT (sector_code) DO UPDATE SET
    name = EXCLUDED.name, status = 'ACTIVE', sort_order = EXCLUDED.sort_order, updated_at = CURRENT_TIMESTAMP;

INSERT INTO core.sector_questionnaire(questionnaire_api_id, sector_code, definition_version, status)
SELECT 'sq_' || lower(sector_code), sector_code, 1, 'ACTIVE'
FROM core.sector
WHERE sector_code IN (
    'TECHNOLOGY','FINANCIAL_SERVICES','HEALTHCARE','EDUCATION','GOVERNMENT','MANUFACTURING','RETAIL',
    'TELECOMMUNICATIONS','MEDIA','ENERGY','CONSTRUCTION','LOGISTICS','PROFESSIONAL_SERVICES',
    'AGRICULTURE','TRAVEL','NONPROFIT','OTHER'
)
ON CONFLICT (questionnaire_api_id) DO UPDATE SET status = 'ACTIVE', updated_at = CURRENT_TIMESTAMP;

WITH question_seed(question_api_id, sector_code, question_code, prompt, answer_type, is_required, sort_order, options_text) AS (VALUES
    ('q_role_v1',NULL,'ROLE','What best describes your role?','SINGLE_SELECT',true,10,'FOUNDER:Founder or business owner|EXECUTIVE:Executive or senior leader|BUSINESS_DEVELOPMENT:Sales or business development|PRODUCT:Product or programme management|TECHNOLOGY:Technology or engineering|OPERATIONS:Operations or supply chain|MARKETING:Marketing or communications|FINANCE:Finance|INVESTOR:Investor|ADVISOR:Advisor or consultant|RESEARCHER:Researcher or academic|POLICYMAKER:Government or policymaker|OTHER:Other'),
    ('q_organization_provides_v1',NULL,'ORGANIZATION_PROVIDES','What does your organization primarily provide?','MULTI_SELECT',true,20,'PRODUCTS:Physical products|SOFTWARE:Software or technology|SERVICES:Professional services|MANUFACTURING:Manufacturing|DISTRIBUTION:Distribution or logistics|FUNDING:Funding or investment|RESEARCH:Research or intellectual property|EDUCATION:Education or training|INFRASTRUCTURE:Infrastructure|PUBLIC_SERVICES:Public services|SOCIAL_SERVICES:Nonprofit or social services|OTHER:Other'),
    ('q_customer_segments_v1',NULL,'CUSTOMER_SEGMENTS','Who do you primarily serve?','MULTI_SELECT',true,30,'CONSUMERS:Consumers|STARTUPS:Startups|SMES:Small and medium businesses|ENTERPRISES:Large enterprises|GOVERNMENT:Government|NONPROFITS:Nonprofit organizations|INVESTORS:Investors|EDUCATION:Educational institutions|HEALTHCARE:Healthcare organizations|OTHER:Other'),
    ('q_offers_v1',NULL,'OFFERS','What can you help other members with?','MULTI_SELECT',true,40,'EXPERTISE:Industry expertise|INTRODUCTIONS:Business introductions|FUNDING:Investment or funding|TECHNOLOGY:Technology|DISTRIBUTION:Sales or distribution|MARKET_ACCESS:Market access|TALENT:Hiring or talent|PROCUREMENT:Procurement or suppliers|RESEARCH:Research|ADVISORY:Mentoring or advisory|POLICY:Government or policy connections|OTHER:Other'),
    ('q_needs_v1',NULL,'NEEDS','What are you currently looking for?','MULTI_SELECT',true,50,'CLIENTS:Clients or customers|SUPPLIERS:Suppliers|DISTRIBUTORS:Distributors|FUNDING:Investors or funding|INVESTMENTS:Investment opportunities|TECHNOLOGY:Technology partners|PARTNERS:Business partners|TALENT:Talent|ADVISORS:Advisors or mentors|RESEARCH:Research partners|POLICY:Government or policy connections|COFOUNDERS:Co-founders|OTHER:Other'),
    ('q_markets_v1',NULL,'MARKETS','Which markets do you operate in or want to enter?','TEXT',false,60,NULL),

    ('q_technology_product_v1','TECHNOLOGY','TECH_PRODUCT','What type of technology or product do you provide?','MULTI_SELECT',true,110,'SAAS:SaaS|AI_ML:AI / ML|CYBERSECURITY:Cybersecurity|CLOUD:Cloud|DATA:Data and analytics|HARDWARE:Hardware|MARKETPLACE:Marketplace|DEV_TOOLS:Developer tools|ENTERPRISE_SOFTWARE:Enterprise software|CONSUMER_APP:Consumer application|OTHER:Other'),
    ('q_technology_buyer_v1','TECHNOLOGY','TECH_BUYER','Who normally buys or uses your solution?','MULTI_SELECT',true,120,'CONSUMERS:Consumers|STARTUPS:Startups|SMES:SMEs|ENTERPRISES:Enterprises|GOVERNMENT:Government|DEVELOPERS:Developers|OTHER:Industry-specific organizations'),
    ('q_technology_stage_v1','TECHNOLOGY','TECH_STAGE','What stage is the product or business?','SINGLE_SELECT',true,130,'IDEA:Idea|PROTOTYPE:Prototype|LAUNCHED:Launched|EARLY_REVENUE:Early revenue|GROWTH:Growth|ESTABLISHED:Established'),

    ('q_finance_segment_v1','FINANCIAL_SERVICES','FINANCE_SEGMENT','Which financial-services segment best describes your work?','MULTI_SELECT',true,110,'BANKING:Banking|PAYMENTS:Payments|LENDING:Lending|INSURANCE:Insurance|WEALTH:Wealth management|CAPITAL_MARKETS:Capital markets|REGTECH:Regtech|FINTECH_INFRA:Fintech infrastructure|OTHER:Other'),
    ('q_finance_model_v1','FINANCIAL_SERVICES','FINANCE_MODEL','What is your operating model?','MULTI_SELECT',true,120,'REGULATED:Regulated institution|TECH_PROVIDER:Technology provider|INTERMEDIARY:Intermediary|ADVISOR:Advisor|INVESTOR:Investor|SERVICE_PROVIDER:Service provider'),
    ('q_finance_seeking_v1','FINANCIAL_SERVICES','FINANCE_SEEKING','What type of partnership are you seeking?','MULTI_SELECT',true,130,'CUSTOMERS:Customers|REGULATED_PARTNERS:Regulated partners|DISTRIBUTION:Distribution|INTEGRATION:Technology integration|FUNDING:Funding|INVESTMENTS:Investment opportunities|MARKET_ACCESS:Market access'),

    ('q_healthcare_area_v1','HEALTHCARE','HEALTHCARE_AREA','Which healthcare area best describes your work?','MULTI_SELECT',true,110,'PROVIDER:Healthcare provider|PHARMA:Pharmaceutical|BIOTECH:Biotechnology|MEDTECH:Medical devices|DIAGNOSTICS:Diagnostics|HEALTHTECH:Health technology|WELLNESS:Wellness|SERVICES:Healthcare services|OTHER:Other'),
    ('q_healthcare_value_chain_v1','HEALTHCARE','HEALTHCARE_VALUE_CHAIN','Where do you operate in the healthcare value chain?','MULTI_SELECT',true,120,'RESEARCH:Research|DEVELOPMENT:Development|MANUFACTURING:Manufacturing|CLINICAL:Clinical delivery|DISTRIBUTION:Distribution|TECHNOLOGY:Technology|CONSULTING:Consulting|INVESTMENT:Investment'),
    ('q_healthcare_seeking_v1','HEALTHCARE','HEALTHCARE_SEEKING','What type of collaboration are you seeking?','MULTI_SELECT',true,130,'RESEARCH:Research|CLINICAL:Clinical partners|PROVIDERS:Providers|DISTRIBUTORS:Distributors|INVESTORS:Investors|TECHNOLOGY:Technology partners|SUPPLIERS:Suppliers|MARKET_ACCESS:Market access'),

    ('q_education_segment_v1','EDUCATION','EDUCATION_SEGMENT','Which education segment do you serve?','MULTI_SELECT',true,110,'K12:K-12|HIGHER_ED:Higher education|VOCATIONAL:Vocational training|CORPORATE:Corporate learning|CERTIFICATION:Professional certification|EDTECH:Edtech|OTHER:Other'),
    ('q_education_delivery_v1','EDUCATION','EDUCATION_DELIVERY','How is the education or training delivered?','MULTI_SELECT',true,120,'ONLINE:Online|IN_PERSON:In person|HYBRID:Hybrid|LICENSING:Institutional licensing|EMPLOYER:Employer-sponsored'),
    ('q_education_seeking_v1','EDUCATION','EDUCATION_SEEKING','What type of partner are you looking for?','MULTI_SELECT',true,130,'INSTITUTIONS:Educational institutions|EMPLOYERS:Employers|TRAINERS:Trainers|CONTENT:Content providers|TECHNOLOGY:Technology providers|FUNDERS:Funders|GOVERNMENT:Government'),

    ('q_government_area_v1','GOVERNMENT','GOVERNMENT_AREA','Which public-service or policy areas are relevant to your work?','MULTI_SELECT',true,110,'ECONOMIC_DEVELOPMENT:Economic development|HEALTHCARE:Healthcare|EDUCATION:Education|INFRASTRUCTURE:Infrastructure|DIGITAL_GOVERNMENT:Digital government|SUSTAINABILITY:Sustainability|PUBLIC_SAFETY:Public safety|INVESTMENT_PROMOTION:Investment promotion|OTHER:Other'),
    ('q_government_role_v1','GOVERNMENT','GOVERNMENT_ROLE','What best describes your current public-sector role?','MULTI_SELECT',true,120,'POLICY:Policymaking|SERVICE_DELIVERY:Service delivery|PROGRAMME:Programme management|PROCUREMENT:Procurement|REGULATION:Regulation|ECOSYSTEM:Ecosystem development|ADVISORY:Advisory'),
    ('q_government_seeking_v1','GOVERNMENT','GOVERNMENT_SEEKING','What external support or collaboration is relevant?','MULTI_SELECT',true,130,'TECHNOLOGY:Technology|SUPPLIERS:Suppliers|RESEARCH:Research|INVESTMENT:Investment|EXPERTISE:Industry expertise|IMPLEMENTATION:Implementation partners|PPP:Public-private partnerships'),

    ('q_manufacturing_product_v1','MANUFACTURING','MANUFACTURING_PRODUCT','What do you manufacture or support?','MULTI_SELECT',true,110,'CONSUMER_GOODS:Consumer goods|INDUSTRIAL_EQUIPMENT:Industrial equipment|ELECTRONICS:Electronics|AUTOMOTIVE:Automotive|CHEMICALS:Chemicals|PHARMA:Pharmaceuticals|MATERIALS:Materials|PACKAGING:Packaging|OTHER:Other'),
    ('q_manufacturing_capability_v1','MANUFACTURING','MANUFACTURING_CAPABILITY','Which capabilities do you provide?','MULTI_SELECT',true,120,'DESIGN:Product design|COMPONENTS:Component manufacturing|ASSEMBLY:Assembly|CONTRACT:Contract manufacturing|TESTING:Quality testing|AUTOMATION:Automation|MAINTENANCE:Maintenance|DISTRIBUTION:Distribution'),
    ('q_manufacturing_seeking_v1','MANUFACTURING','MANUFACTURING_SEEKING','What are you currently seeking?','MULTI_SELECT',true,130,'BUYERS:Buyers|SUPPLIERS:Suppliers|CONTRACT_MANUFACTURERS:Contract manufacturers|AUTOMATION:Automation|FINANCING:Financing|TECHNOLOGY:Technology|DISTRIBUTORS:Distributors|EXPANSION:Market expansion'),

    ('q_retail_category_v1','RETAIL','RETAIL_CATEGORY','Which product categories are relevant?','MULTI_SELECT',true,110,'FOOD_BEVERAGE:Food and beverage|FASHION:Fashion|BEAUTY:Beauty|ELECTRONICS:Electronics|HOME:Home|HEALTH:Health|LUXURY:Luxury|GENERAL:General merchandise|OTHER:Other'),
    ('q_retail_channel_v1','RETAIL','RETAIL_CHANNEL','Which sales channels do you use?','MULTI_SELECT',true,120,'PHYSICAL:Physical retail|OWN_ECOMMERCE:Own e-commerce|MARKETPLACES:Marketplaces|WHOLESALE:Wholesale|DISTRIBUTORS:Distributors|SOCIAL:Social commerce'),
    ('q_retail_seeking_v1','RETAIL','RETAIL_SEEKING','What type of partner are you seeking?','MULTI_SELECT',true,130,'BRANDS:Brands|RETAILERS:Retailers|DISTRIBUTORS:Distributors|MARKETPLACES:Marketplaces|LOGISTICS:Logistics|MARKETING:Marketing|TECHNOLOGY:Technology|INVESTORS:Investors'),

    ('q_telecom_area_v1','TELECOMMUNICATIONS','TELECOM_AREA','Which telecommunications area best describes your work?','MULTI_SELECT',true,110,'OPERATOR:Network operator|INFRASTRUCTURE:Infrastructure|CONNECTIVITY:Connectivity|ENTERPRISE:Enterprise solutions|DEVICES:Devices|IOT:IoT|SOFTWARE:Telecom software|OTHER:Other'),
    ('q_telecom_customer_v1','TELECOMMUNICATIONS','TELECOM_CUSTOMER','Which customer segments do you serve?','MULTI_SELECT',true,120,'CONSUMERS:Consumers|SMES:SMEs|ENTERPRISES:Enterprises|GOVERNMENT:Government|OPERATORS:Operators|TECH_PROVIDERS:Technology providers'),
    ('q_telecom_seeking_v1','TELECOMMUNICATIONS','TELECOM_SEEKING','What type of partnership is relevant?','MULTI_SELECT',true,130,'INFRASTRUCTURE:Infrastructure|TECHNOLOGY:Technology|CUSTOMERS:Enterprise customers|DISTRIBUTION:Distribution|INTEGRATION:Integration|INVESTMENT:Investment|GOVERNMENT:Government relationships'),

    ('q_media_capability_v1','MEDIA','MEDIA_CAPABILITY','Which capabilities do you provide?','MULTI_SELECT',true,110,'ADVERTISING:Advertising|BRANDING:Branding|PR:Public relations|CONTENT:Content creation|PUBLISHING:Publishing|PRODUCTION:Film or video production|EVENTS:Events|INFLUENCER:Influencer marketing|OTHER:Other'),
    ('q_media_platform_v1','MEDIA','MEDIA_PLATFORM','Which audiences or platforms are most relevant?','MULTI_SELECT',true,120,'CONSUMER:Consumer|B2B:B2B|TELEVISION:Television|PRINT:Print|DIGITAL:Digital|SOCIAL:Social media|STREAMING:Streaming|LIVE:Live events'),
    ('q_media_seeking_v1','MEDIA','MEDIA_SEEKING','What type of collaboration are you seeking?','MULTI_SELECT',true,130,'CLIENTS:Clients|SPONSORS:Sponsors|CREATORS:Creators|DISTRIBUTION:Distribution|PRODUCTION:Production partners|TECHNOLOGY:Technology|INVESTMENT:Investment'),

    ('q_energy_area_v1','ENERGY','ENERGY_AREA','Which area best describes your work?','MULTI_SELECT',true,110,'RENEWABLE:Renewable energy|CONVENTIONAL:Conventional energy|GRID:Grid|STORAGE:Energy storage|WATER:Water|WASTE:Waste|CARBON:Carbon management|CLIMATE_TECH:Climate technology|OTHER:Other'),
    ('q_energy_stage_v1','ENERGY','ENERGY_STAGE','What project stage do you support?','MULTI_SELECT',true,120,'RESEARCH:Research|DEVELOPMENT:Development|FINANCING:Financing|CONSTRUCTION:Construction|OPERATIONS:Operations|TECHNOLOGY:Technology|ADVISORY:Advisory'),
    ('q_energy_seeking_v1','ENERGY','ENERGY_SEEKING','What are you seeking?','MULTI_SELECT',true,130,'CAPITAL:Project capital|SITES:Sites|CUSTOMERS:Customers|TECHNOLOGY:Technology|SUPPLIERS:Suppliers|IMPLEMENTATION:Implementation partners|GOVERNMENT:Government relationships'),

    ('q_construction_asset_v1','CONSTRUCTION','CONSTRUCTION_ASSET','Which asset classes are relevant?','MULTI_SELECT',true,110,'RESIDENTIAL:Residential|COMMERCIAL:Commercial|INDUSTRIAL:Industrial|HOSPITALITY:Hospitality|MIXED_USE:Mixed-use|PUBLIC_INFRA:Public infrastructure'),
    ('q_construction_role_v1','CONSTRUCTION','CONSTRUCTION_ROLE','What is your role in the project lifecycle?','MULTI_SELECT',true,120,'DEVELOPMENT:Development|INVESTMENT:Investment|DESIGN:Design|CONSTRUCTION:Construction|SUPPLY:Supply|OPERATIONS:Operations|TECHNOLOGY:Technology|ADVISORY:Advisory'),
    ('q_construction_seeking_v1','CONSTRUCTION','CONSTRUCTION_SEEKING','What are you seeking?','MULTI_SELECT',true,130,'PROJECTS:Projects|CAPITAL:Capital|CONTRACTORS:Contractors|SUPPLIERS:Suppliers|TECHNOLOGY:Technology|TENANTS:Tenants|BUYERS:Buyers|GOVERNMENT:Government relationships'),

    ('q_logistics_service_v1','LOGISTICS','LOGISTICS_SERVICE','Which logistics or mobility services do you provide?','MULTI_SELECT',true,110,'FREIGHT:Freight|WAREHOUSING:Warehousing|LAST_MILE:Last-mile delivery|COLD_CHAIN:Cold chain|CUSTOMS:Customs|FLEET:Fleet services|MOBILITY:Mobility|SOFTWARE:Supply-chain software'),
    ('q_logistics_mode_v1','LOGISTICS','LOGISTICS_MODE','Which transport modes do you support?','MULTI_SELECT',true,120,'ROAD:Road|AIR:Air|SEA:Sea|RAIL:Rail|MULTIMODAL:Multimodal'),
    ('q_logistics_seeking_v1','LOGISTICS','LOGISTICS_SEEKING','What are you currently seeking?','MULTI_SELECT',true,130,'SHIPPERS:Shippers|CARRIERS:Carriers|WAREHOUSE:Warehouse capacity|TECHNOLOGY:Technology|INFRASTRUCTURE:Infrastructure|FINANCING:Financing|EXPANSION:Market expansion'),

    ('q_professional_discipline_v1','PROFESSIONAL_SERVICES','PROFESSIONAL_DISCIPLINE','Which professional discipline best describes your work?','MULTI_SELECT',true,110,'CONSULTING:Consulting|LEGAL:Legal|ACCOUNTING:Accounting|RECRUITMENT:Recruitment|HR:HR|DESIGN:Design|OUTSOURCING:Outsourced operations|COMPLIANCE:Compliance|OTHER:Other'),
    ('q_professional_client_v1','PROFESSIONAL_SERVICES','PROFESSIONAL_CLIENT','Which types of clients do you primarily serve?','MULTI_SELECT',true,120,'STARTUPS:Startups|SMES:SMEs|ENTERPRISES:Enterprises|GOVERNMENT:Government|NONPROFITS:Nonprofits|INDIVIDUALS:Individuals'),
    ('q_professional_seeking_v1','PROFESSIONAL_SERVICES','PROFESSIONAL_SEEKING','What type of opportunities are relevant?','MULTI_SELECT',true,130,'CLIENTS:Clients|REFERRALS:Referral partners|DELIVERY:Delivery partners|EXPERTISE:Specialist expertise|GEOGRAPHY:Geographic coverage|PARTNERSHIPS:Strategic partnerships'),

    ('q_agriculture_value_chain_v1','AGRICULTURE','AGRICULTURE_VALUE_CHAIN','Where do you operate in the value chain?','MULTI_SELECT',true,110,'FARMING:Farming|INPUTS:Inputs|PROCESSING:Processing|INGREDIENTS:Ingredients|MANUFACTURING:Food manufacturing|DISTRIBUTION:Distribution|BRANDS:Food brands|FOOD_SERVICE:Food service|AGTECH:Agtech'),
    ('q_agriculture_category_v1','AGRICULTURE','AGRICULTURE_CATEGORY','Which product categories are relevant?','TEXT',true,120,NULL),
    ('q_agriculture_seeking_v1','AGRICULTURE','AGRICULTURE_SEEKING','What are you currently seeking?','MULTI_SELECT',true,130,'BUYERS:Buyers|SUPPLIERS:Suppliers|TECHNOLOGY:Technology|FINANCING:Financing|PROCESSING:Processing capacity|DISTRIBUTORS:Distributors|CERTIFICATION:Certification support|MARKET_ACCESS:Market access'),

    ('q_travel_segment_v1','TRAVEL','TRAVEL_SEGMENT','Which segment best describes your work?','MULTI_SELECT',true,110,'ACCOMMODATION:Accommodation|TOURISM:Tourism|TRAVEL_SERVICES:Travel services|TRAVEL_TECH:Travel technology|VENUES:Venues|EVENTS:Corporate events|DESTINATION:Destination services'),
    ('q_travel_customer_v1','TRAVEL','TRAVEL_CUSTOMER','Which customer groups do you serve?','MULTI_SELECT',true,120,'LEISURE:Leisure travellers|BUSINESS:Business travellers|GROUPS:Groups|ENTERPRISES:Enterprises|ORGANIZERS:Event organizers|GOVERNMENT:Government'),
    ('q_travel_seeking_v1','TRAVEL','TRAVEL_SEEKING','What type of partnership are you seeking?','MULTI_SELECT',true,130,'DISTRIBUTION:Distribution|CORPORATE_CLIENTS:Corporate clients|SUPPLIERS:Suppliers|VENUES:Venues|SPONSORS:Sponsors|TECHNOLOGY:Technology|DESTINATIONS:Destination partners'),

    ('q_nonprofit_cause_v1','NONPROFIT','NONPROFIT_CAUSE','Which cause areas are relevant?','MULTI_SELECT',true,110,'EDUCATION:Education|HEALTH:Health|ENVIRONMENT:Environment|POVERTY:Poverty reduction|YOUTH:Youth|INCLUSION:Inclusion|HUMANITARIAN:Humanitarian support|COMMUNITY:Community development'),
    ('q_nonprofit_model_v1','NONPROFIT','NONPROFIT_MODEL','What is your operating model?','MULTI_SELECT',true,120,'DIRECT_SERVICE:Direct service|ADVOCACY:Advocacy|GRANTMAKING:Grantmaking|RESEARCH:Research|CAPACITY:Capacity building|SOCIAL_ENTERPRISE:Social enterprise'),
    ('q_nonprofit_seeking_v1','NONPROFIT','NONPROFIT_SEEKING','What type of support are you seeking?','MULTI_SELECT',true,130,'FUNDING:Funding|VOLUNTEERS:Volunteers|CORPORATE:Corporate partners|GOVERNMENT:Government relationships|TECHNOLOGY:Technology|EXPERTISE:Expertise|DELIVERY:Delivery partners'),

    ('q_other_industry_v1','OTHER','OTHER_INDUSTRY','How would you describe your industry or field?','TEXT',true,110,NULL),
    ('q_other_work_v1','OTHER','OTHER_WORK','What does your organization do?','TEXT',true,120,NULL),
    ('q_other_counterpart_v1','OTHER','OTHER_COUNTERPART','What type of people or organizations would be useful to meet?','TEXT',true,130,NULL)
)
INSERT INTO core.profile_question(
    question_api_id, sector_code, question_code, question_version, prompt, answer_type,
    is_required, sort_order, configuration_json, status
)
SELECT question_api_id, sector_code, question_code, 1, prompt, answer_type, is_required, sort_order,
       CASE
           WHEN options_text IS NULL THEN jsonb_build_object('max_length', 1000)
           ELSE jsonb_build_object(
               'options', (
                   SELECT jsonb_agg(
                       jsonb_build_object('code', split_part(option_value, ':', 1), 'label', split_part(option_value, ':', 2))
                       ORDER BY option_order
                   )
                   FROM unnest(string_to_array(options_text, '|')) WITH ORDINALITY AS option_row(option_value, option_order)
               ),
               'min_selections', 1,
               'max_selections', CASE WHEN answer_type = 'SINGLE_SELECT' THEN 1 WHEN sort_order < 100 THEN 8 ELSE 5 END
           )
       END,
       'ACTIVE'
FROM question_seed
ON CONFLICT (question_api_id) DO NOTHING;

INSERT INTO core.sector_questionnaire_question(
    sector_questionnaire_id, definition_version, profile_question_id, is_required, sort_order
)
SELECT sq.sector_questionnaire_id, sq.definition_version, q.profile_question_id, q.is_required, q.sort_order
FROM core.sector_questionnaire sq
JOIN core.profile_question q ON q.status = 'ACTIVE' AND (q.sector_code IS NULL OR q.sector_code = sq.sector_code)
WHERE sq.status = 'ACTIVE'
ON CONFLICT (sector_questionnaire_id, definition_version, profile_question_id) DO NOTHING;

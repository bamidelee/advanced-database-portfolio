# MIT 8103 Advanced Database Systems Portfolio

**Student:** Ibrahim Olubamidele Olujide
**Matric/Student ID:** 301910809
**Programme:** Master of Information Technology, MIVA Open University
**Session:** 2026/2027 First Semester (September cohort)

## Case Study: AquaFlow Water Delivery Ltd (simulated)

## Case Study: AquaFlow Water Tanker Services

### Organisation and Scenario
AquaFlow is a simulated on-demand water tanker platform, operating like a ride-hailing service for water, on Lagos Island, Nigeria. Many households and businesses in areas such as Lagos Island, Ikoyi, Victoria Island, and Obalende cannot use their borehole or well water because of saltwater intrusion: seawater from the Atlantic Ocean and the Lagos Lagoon has seeped into the shallow aquifers that boreholes draw from, pushing chloride levels above the WHO limit for safe water [1][2][3]. Reaching fresh water requires very deep boreholes that most property owners cannot afford [1], and surface pollution from sewage and industrial waste further degrades groundwater [4]. As a result, residents rely on water tankers to fill their storage tanks.

AquaFlow connects these customers with independent vendors who own and operate their own water tankers. The platform matches each request to a nearby available tanker, tracks the delivery live, processes payment, and pays vendors after deducting a commission.

### Nature of the Business
Customers request a delivery through the AquaFlow customer app, specifying the delivery address and volume needed, either immediately or at a scheduled time. The platform finds available tankers near the customer with enough capacity and sends the request to their vendors through the AquaFlow vendor app. The first vendor to accept is assigned the job, and the tanker's location is tracked live until it arrives. The driver confirms the volume delivered, the customer pays by card or bank transfer through the app, and the vendor's earnings, minus AquaFlow's commission, are credited for payout.

### Users of the Database
- **Customers** (households and businesses) register addresses, request deliveries, pay, track tankers in real time, and rate completed deliveries.
- **Vendors** (tanker owners) register their tankers and drivers, accept or decline requests, and receive payouts. A vendor may own one or several tankers.
- **Drivers** operate tankers on behalf of vendors, share live location, and update delivery status. A vendor may also drive their own tanker.
- **Operations staff** monitor active deliveries, resolve disputes, and manage service areas and pricing.
- **Finance staff** reconcile customer payments, commissions, refunds, and vendor payouts.

### Major Data Stored
Customers and delivery addresses (including storage tank capacity and access notes), service areas, vendors, tankers (capacity, plate number, availability status), drivers, pricing rules, delivery requests, job offers and acceptances, delivery status history, live tanker locations, payments, refunds, commissions, vendor payouts, and ratings.

### Key Operations
- Register customers, vendors, tankers, and drivers
- Request a water delivery (immediate or scheduled)
- Find nearby available tankers with sufficient capacity
- Offer jobs to vendors and assign each job to exactly one tanker
- Track tanker location and delivery status in real time
- Confirm delivered volume and process payment
- Reverse failed payments and refund cancelled deliveries
- Calculate commissions and credit vendor earnings for payout
- Generate reports on demand per area, vendor performance, delivery times, and revenue

### References
1. Delineation of saline water intrusion to safe-guide inland groundwater resources (Lagos Island). *Ocean & Coastal Management*, Vol. 116, 2015, pp. 162–168.
2. Assessment of Saline Intrusion in Lagos Coastal Aquifer. *International Archive of Applied Sciences and Technology*, Vol. 3, No. 3, 2012, pp. 23–28.
3. Yusuf, M. A., Ojulari, B. A., Ibrahim, K. O., & Abiye, T. A. (2021). Assessment of saltwater–freshwater interactions using water samples and borehole logging information in the Lagos coastal region, Nigeria. *Environmental Earth Sciences*.
4. Hydrogeochemical processes and salinity status of the freshwater aquifer in the Lagos coastal basin. Available via PubMed Central (PMC8564569).

## Portfolio Contents
| Portfolio | Topic | Folder |
|---|---|---|
| 1 | Database Design and Modelling | portfolio-1-database-design/ |
| 2 | Query Processing and Optimisation | portfolio-2-query-optimisation/ |
| 3 | Transactions and Concurrency | portfolio-3-transactions-concurrency/ |
| 4 | NoSQL and Advanced Data Models | portfolio-4-nosql/ |
| 5 | Distributed and Cloud Database | portfolio-5-distributed-cloud/ |

## Tools Used
PostgreSQL, MongoDB, Redis, Docker

## AI Use Declaration
[To be completed]
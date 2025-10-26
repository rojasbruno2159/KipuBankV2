# KipuBankV2

**KipuBankV2** es una versión mejorada del contrato inteligente original **KipuBank**.  
Introduce una arquitectura modular, control de acceso, contabilidad multi-token y límites basados en USD utilizando oráculos de Chainlink.  
Esta versión está pensada para simular un contrato cercano a producción, con buena estructura, seguridad y documentación clara.

---

## Descripción General de las Mejoras

Este proyecto evoluciona el contrato original de una bóveda de ETH a un sistema más flexible y seguro, incorporando:

- **Control de Acceso (OpenZeppelin)** – Permisos basados en roles mediante `AccessControl`, garantizando que solo los administradores autorizados puedan configurar los activos y los oráculos.
- **Declaraciones de Tipos (Types.sol)** – Librería separada que define la estructura de configuración de activos y la constante que representa ETH nativo.
- **Oráculo Chainlink Integrado** – Conversión en tiempo real usando `AggregatorV3Interface` para ETH/USD y, opcionalmente, para tokens ERC-20.
- **Variables Constantes e Inmutables** – Parámetros como `bankCapUsd`, `withdrawLimitPerTxNative` y los decimales USDC fijos para mejorar la eficiencia de gas.
- **Mappings Anidados** – Contabilidad interna como `mapping(address => mapping(address => uint256))`, lo que permite balances por usuario y por token.
- **Funciones de Conversión de Decimales (Decimals.sol)** – Estandariza la conversión de montos de tokens a unidades de 6 decimales (USDC).
- **Diseño Seguro y Optimizado en Gas** – Uso de `SafeERC20`, patrón *checks-effects-interactions*, bloqueo anti-reentrancia liviano y reducción de lecturas redundantes del oráculo.

---

## Instrucciones de Despliegue (Remix + Sepolia Testnet)

1. **Abrir Remix IDE**  
   Ir a [https://remix.ethereum.org](https://remix.ethereum.org) y cargar los tres archivos fuente que estan dentro de la carpeta `/src`:  
   - `KipuBankV2.sol`  
   - `Decimals.sol`  
   - `Types.sol`

2. **Compilar**  
   - Ir a la pestaña **Solidity Compiler**.  
   - Seleccionar la versión `0.8.20`.  
   - Asegurarse de que la optimización esté **activada**.  
   - Hacer clic en **Compile KipuBankV2.sol**.

3. **Desplegar en Sepolia**  
   - Ir a la pestaña **Deploy & Run Transactions**.  
   - En **Environment**, seleccionar `Injected Provider – MetaMask`.  
   - Confirmar que MetaMask esté conectado a la red **Sepolia Testnet** y que tengas ETH de prueba.  
   - Seleccionar el contrato `KipuBankV2`.  
   - Completar los parámetros del constructor:
     ```
     _bankCapUsd:          1000000000        // Ejemplo: 1.000 USDC de límite (6 decimales)
     _withdrawLimitPerTxNative: 100000000000000000   // 0.1 ETH por transacción
     _ethUsdFeed:          0x694AA1769357215DE4FAC081bf1f309aDC325306
     ```
   - Hacer clic en **Deploy** y confirmar en MetaMask.

4. **Verificación en Sepolia Etherscan (opcional, recomendada)**  
   - Ir a [https://sepolia.etherscan.io/verifyContract](https://sepolia.etherscan.io/verifyContract).  
   - Pegar la dirección del contrato desplegado.  
   - Compilador: `v0.8.20+commit.a1b79de6`.  
   - Licencia: `MIT`.  
   - Pegar el código *flattened* desde Remix (botón derecho sobre KipuBankV2.sol → *Flatten*).  
   - Hacer clic en **Verify and Publish**.  
   Una vez verificado, el contrato aparecerá en Sepolia Etherscan con las pestañas **Code**, **Read**, y **Write Contract**.

---

## Ejemplos de Interacción (en Remix)

Después de desplegar, podés interactuar con el contrato desde Remix o directamente desde Sepolia Etherscan.

- **Depositar ETH**
  - Función: `depositNative()`
  - Ingresar un valor en `Value (ETH)` (por ejemplo `0.05`).
  - Clic en **transact**.

- **Depositar Tokens ERC-20**
  - Primero ejecutar `approve(KipuBankV2_address, amount)` en el contrato del token.
  - Luego llamar `depositToken(tokenAddress, amount)`.

- **Retirar ETH**
  - Función: `withdrawNative(amountWei)`
  - Ejemplo: `10000000000000000` (0.01 ETH).

- **Retirar Tokens**
  - Función: `withdrawToken(tokenAddress, amount)`.

- **Consultar Balances**
  - `getBalanceUSDC(tokenAddress, userAddress)` devuelve el balance del usuario en formato USDC (6 decimales).

---
## Soporte Multi-token

KipuBankV2 permite gestionar múltiples activos dentro de una misma bóveda.  
Cada token ERC-20 se registra mediante la función `setAssetConfig()`, la cual solo puede ejecutar un usuario con rol de administrador.

Una vez configurado, el contrato:

- Asocia el token a su oráculo de precios Chainlink (por ejemplo, USDC/USD o LINK/USD).  
- Permite depósitos y retiros de ese token de forma independiente.
- Convierte internamente el valor de cada depósito a su equivalente en USD (6 decimales) para fines contables, sin realizar swaps reales.

## Notas de Diseño y Trade-offs

- **Eficiencia de Gas vs Flexibilidad**  
  Algunos valores (como el feed ETH/USD) son inmutables para reducir gas, pero no pueden modificarse después del despliegue.  
  Esto mejora la seguridad a cambio de menor flexibilidad.

- **Registro Manual de Oráculos**  
  Cada token ERC-20 debe registrarse manualmente por un administrador con un feed Chainlink válido.  
  Esto evita asignaciones erróneas o maliciosas.

- **Bloqueo Anti-Reentrancia Simplificado**  
  Se usa un booleano interno en lugar de `ReentrancyGuard` para reducir el tamaño del bytecode y el gas, sin comprometer la seguridad.

- **Estandarización en 6 Decimales (USDC)**  
  Toda la contabilidad interna se maneja en formato USDC (6 decimales), lo que simplifica los cálculos y los límites globales en USD.

- **Seguridad General**  
  Las transferencias utilizan `SafeERC20`, las operaciones siguen el patrón *checks-effects-interactions*, y no existen funciones `receive()` o `fallback()` para evitar depósitos accidentales.

---

## Resumen de Configuración

| Parámetro | Descripción | Ejemplo |
|------------|--------------|----------|
| `_bankCapUsd` | Límite global de depósitos (en 6 decimales) | `1000000000` (1.000 USDC) |
| `_withdrawLimitPerTxNative` | Límite máximo por retiro de ETH | `100000000000000000` (0.1 ETH) |
| `_ethUsdFeed` | Feed Chainlink ETH/USD (Sepolia) | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
